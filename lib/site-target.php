<?php
/** Resolve locally discovered installations; no DNS, network or WordPress bootstrap. */
function pg_site_name($value) {
    if (!is_string($value) || $value === '' || strlen($value) > 2048
        || preg_match('~[\x00-\x20\x7f\\\\?#@%]~', $value)) return null;
    $url = preg_match('~^https?://~i', $value) ? $value : 'https://'.$value;
    $p = parse_url($url);
    if (!is_array($p) || !isset($p['host']) || isset($p['user'], $p['pass'])
        || isset($p['port']) || !in_array(strtolower($p['scheme'] ?? ''), ['http', 'https'], true)) return null;
    $host = strtolower(rtrim($p['host'], '.'));
    if (strlen($host) > 253 || strpos($host, '.') === false) return null;
    foreach (explode('.', $host) as $label) {
        if (!preg_match('~^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$~D', $label)) return null;
    }
    $path = rtrim($p['path'] ?? '', '/');
    if ($path !== '' && (!preg_match('~^/(?:[A-Za-z0-9._\~-]+/?)+$~D', $path) || preg_match('~/(?:\.|\.\.)(?:/|$)~', $path))) return null;
    return $host.$path;
}

function pg_site_directory_name($site, $scope) {
    // A domain-shaped folder is a local name, not a DNS/ownership assertion.
    $p = $site; $tail = [];
    while ($p === $scope || strpos($p, rtrim($scope, '/').'/') === 0) {
        $base = basename($p); $host = pg_site_name($base);
        if ($host !== null && strpos($host, '/') === false) {
            if ($tail && in_array($tail[0], ['public_html', 'httpdocs', 'htdocs', 'www', 'html'], true)) array_shift($tail);
            return pg_site_name($host.($tail ? '/'.implode('/', $tail) : ''));
        }
        if ($p === $scope) break;
        array_unshift($tail, $base); $p = dirname($p);
    }
    // A configured root may itself be one site's document root.
    if ($site === $scope && in_array(basename($site), ['public_html','httpdocs','htdocs','www','html'], true)) {
        return pg_site_name(basename(dirname($site)));
    }
    return null;
}

function pg_site_literal_names($site) {
    $f = $site.'/wp-config.php';
    if (!is_file($f) || is_link($f) || !is_readable($f)) return [];
    $s = @file_get_contents($f, false, null, 0, 262145);
    if ($s === false || strlen($s) > 262144) return [];
    $tokens = [];
    foreach (token_get_all($s) as $t) {
        if (is_array($t) && in_array($t[0], [T_WHITESPACE,T_COMMENT,T_DOC_COMMENT,T_OPEN_TAG], true)) continue;
        $tokens[] = $t;
    }
    $names = []; $depth = 0;
    for ($i=0, $n=count($tokens); $i<$n; ++$i) {
        $t=$tokens[$i];
        if ($t === '{') { ++$depth; continue; }
        if ($t === '}') { --$depth; continue; }
        if ($depth !== 0 || !is_array($t) || $t[0] !== T_STRING || strtolower($t[1]) !== 'define') continue;
        $prev=$tokens[$i-1] ?? null;
        if (is_array($prev) && in_array($prev[0], [T_OBJECT_OPERATOR,T_DOUBLE_COLON,T_FUNCTION], true)) continue;
        $key=$tokens[$i+2] ?? null; $val=$tokens[$i+4] ?? null;
        if (($tokens[$i+1] ?? '') !== '(' || ($tokens[$i+3] ?? '') !== ',' || ($tokens[$i+5] ?? '') !== ')'
            || !is_array($key) || $key[0] !== T_CONSTANT_ENCAPSED_STRING
            || !is_array($val) || $val[0] !== T_CONSTANT_ENCAPSED_STRING) continue;
        $k=substr($key[1],1,-1); $v=substr($val[1],1,-1);
        // Only plain literal URLs; never interpret escapes, expressions or includes.
        if (!in_array($k, ['WP_HOME','WP_SITEURL'], true) || strpos($v,'\\') !== false) continue;
        $name=pg_site_name($v); if ($name !== null) $names[$name]=true;
    }
    return array_keys($names);
}

function pg_site_index($paths, $scope, $aliases, $exclude) {
    $index=[]; $unknown=[]; $allowed=[]; $excluded=[];
    foreach ($paths as $p) {
        if ($p === '' || preg_match('~[\x00-\x1f\x7f]~', $p) || !is_dir($p)
            || realpath($p) !== $p || ($p !== $scope && strpos($p,rtrim($scope,'/').'/') !== 0)) {
            throw new RuntimeException('Unsafe discovered path');
        }
        $allowed[$p]=true;
        $name=pg_site_directory_name($p,$scope);
        $names=$name !== null ? [$name] : pg_site_literal_names($p);
        if (!$names) $unknown[]=$p;
        foreach ($names as $name) $index[$name][$p]=true;
    }
    foreach (preg_split('~\r?\n~', $aliases) as $line) {
        $line=trim($line); if ($line === '' || $line[0] === '#') continue;
        $parts=explode('=', $line, 2);
        $name=pg_site_name(trim($parts[0])); $p=trim($parts[1] ?? '');
        if ($name === null || $p === '' || $p[0] !== '/' || preg_match('~[\x00-\x1f\x7f]~', $p)) throw new RuntimeException('Invalid site alias');
        $p=realpath($p);
        // Aliases never broaden discovery or bypass exclusions.
        if ($p !== false && isset($allowed[$p])) $index[$name][$p]=true;
    }
    foreach ($index as $name=>$by) {
        foreach (preg_split('~\s+~', trim($exclude)) as $x) {
            if ($x === '') continue;
            $x=pg_site_name($x);
            if ($x !== null && ($x === $name || (strpos($x,'/') === false && $x === explode('/',$name,2)[0]))) foreach($by as $p=>$_) $excluded[$p]=true;
        }
    }
    foreach($index as $name=>$by) {
        foreach($by as $p=>$_) foreach($excluded as $x=>$unused) if($p===$x||strpos($p,$x.'/')===0) unset($index[$name][$p]);
        if(!$index[$name]) unset($index[$name]);
    }
    ksort($index, SORT_STRING);
    return [$index,$unknown,array_keys($excluded)];
}

if (isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    try {
        if ($argc !== 3) throw new RuntimeException('Arguments');
        $raw=stream_get_contents(STDIN, 4194305);
        if ($raw === false || strlen($raw)>4194304 || ($raw!=='' && substr($raw,-1)!=="\0")) throw new RuntimeException('Path limit');
        $input=$raw===''?[]:explode("\0",substr($raw,0,-1)); $paths=[]; $excluded=[];
        if (count($input)>10000) throw new RuntimeException('Site limit');
        foreach($input as $line) {
            $p=explode("\t",$line,2);
            if(count($p)!==2||!in_array($p[0],['S','E'],true)||preg_match('~[\x00-\x1f\x7f]~',$p[1])) throw new RuntimeException('Path record');
            if($p[0]==='S') $paths[]=$p[1]; else $excluded[]=$p[1];
        }
        $aliasFile=getenv('PRESSGARDEN_SITE_ALIASES_FILE')?:''; $aliases='';
        if($aliasFile!=='') {
            if(!is_file($aliasFile)||is_link($aliasFile)) throw new RuntimeException('Alias file');
            $aliases=@file_get_contents($aliasFile,false,null,0,262145);
            if($aliases===false||strlen($aliases)>262144) throw new RuntimeException('Alias file limit');
        }
        [$index,$unknown,$byName]=pg_site_index($paths,$argv[2],$aliases,getenv('PRESSGARDEN_EXCLUDE')?:'');
        $excluded=array_unique(array_merge($excluded,$byName));
        if ($argv[1] === '--list') {
            printf("%-38s %s\n", 'WEBSITE', 'LOCAL DIRECTORY');
            foreach ($index as $name=>$by) foreach ($by as $p=>$_) printf("%-38s %s%s\n",$name,$p,count($by)>1?' [ambiguous name]':'');
            foreach($unknown as $p) printf("%-38s %s\n", '(unnamed; use a local alias)', $p);
            if (!$paths) { fwrite(STDERR,"No WordPress installations found in the configured scan root.\n"); exit(2); }
        } else {
            $name=pg_site_name($argv[1]);
            if ($name === null || !isset($index[$name])) {
                fwrite(STDERR,"Website not found or excluded. Run ./pressgarden sites to see local names; nothing was selected.\n"); exit(2);
            }
            $matches=array_keys($index[$name]);
            if (count($matches)!==1) {
                fwrite(STDERR,"Website name is ambiguous. Run ./pressgarden sites and use an explicit directory; nothing was selected.\n"); exit(2);
            }
            $p=$matches[0]; $count=0;
            foreach ($paths as $s) if ($s===$p || strpos($s,$p.'/')===0) { $skip=false; foreach($excluded as $x) if($s===$x||strpos($s,$x.'/')===0) $skip=true; if(!$skip) ++$count; }
            printf("%s\t%s\t%d\n",$p,$name,$count);
            foreach($excluded as $x) if(strpos($x,$p.'/')===0) printf("E\t%s\n",$x);
        }
    } catch (Throwable $e) {
        fwrite(STDERR,"INCOMPLETE: local website names could not be resolved safely; no target selected.\n"); exit(2);
    }
}
