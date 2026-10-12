<?php
/** Bounded disposable-file cleanup; no WordPress bootstrap or malware removal. */
require_once __DIR__.'/ops-safety.php';
function pg_cleanup_text($text) { return preg_replace('/[\p{Cc}\p{Cf}]/u','?', $text) ?? '(non-UTF8 path withheld)'; }
function pg_cleanup_git_ancestor($path) {
    $dir=dirname($path);while($dir!=='/'&&$dir!=='.'){
        if(file_exists($dir.'/.git')||is_link($dir.'/.git'))return true;
        $parent=dirname($dir);if($parent===$dir)break;$dir=$parent;
    }return false;
}
function pg_cleanup_same(array $a,array $b) {
    foreach(['dev','ino','size','mtime','ctime','mode','uid','gid','nlink'] as $key)
        if(!isset($a[$key],$b[$key])||$a[$key]!==$b[$key])return false;
    return true;
}
function pg_cleanup_nested($site,$path) {
    for($dir=dirname($path);$dir!==$site;$dir=dirname($dir)) {
        if($dir==='/'||strpos($dir,$site.'/')!==0)throw new RuntimeException('candidate escaped selected site');
        clearstatcache();
        if(is_dir($dir.'/wp-admin')&&is_file($dir.'/wp-load.php')&&is_file($dir.'/wp-settings.php'))return true;
    }
    return false;
}
/** Inspect and hash the same bounded stream, then recheck descriptor and path. */
function pg_cleanup_read($path,array $before) {
    clearstatcache(true,$path);$now=pg_ops_regular($path,67108864);
    if(!pg_cleanup_same($before,$now))throw new RuntimeException('candidate changed before inspection');
    $h=@fopen($path,'rb');if(!$h)throw new RuntimeException('unreadable cleanup candidate');
    try {
        $opened=fstat($h);
        if(!$opened||!pg_cleanup_same($before,$opened))throw new RuntimeException('candidate changed while opening');
        $hash=hash_init('sha256');$total=0;$tail='';$suspicious=false;
        while(!feof($h)) {
            $chunk=fread($h,min(65536,$before['size']-$total+1));
            if($chunk===false||($chunk===''&&!feof($h)))throw new RuntimeException('incomplete candidate read');
            $total+=strlen($chunk);
            if($total>$before['size'])throw new RuntimeException('candidate grew during inspection');
            hash_update($hash,$chunk);$window=$tail.$chunk;
            if(preg_match('/<\?(?:php|=)|^#!|<script\b|\b(?:eval|base64_decode|shell_exec)\s*\(/i',$window))$suspicious=true;
            $tail=substr($window,-8192);
        }
        clearstatcache(true,$path);$after=pg_ops_regular($path,67108864);$end=fstat($h);
        if($total!==$before['size']||!$end||!pg_cleanup_same($before,$after)||!pg_cleanup_same($before,$end))
            throw new RuntimeException('candidate changed during inspection');
        return [hash_final($hash),$suspicious];
    } finally {fclose($h);}
}
function pg_cleanup_scan($site,$days,$logs,$development,array $sites) {
    pg_ops_path($site);$cutoff=time()-$days*86400;$stack=[[$site,0,false]];$items=[];$review=[];$seen=0;$bytes=0;
    $nested=array_filter($sites,function($p)use($site){return $p!==$site&&strpos($p,$site.'/')===0;});
    while($stack) {
        list($dir,$depth,$dev)=array_pop($stack);
        if($depth>24)throw new RuntimeException('scan depth limit reached; no cleanup performed');
        clearstatcache();pg_ops_path($dir);$entries=@scandir($dir);
        if($entries===false)throw new RuntimeException('incomplete directory scan; no cleanup performed');
        foreach($entries as $name){if($name==='.'||$name==='..')continue;
            if(++$seen>200000)throw new RuntimeException('scan entry limit reached; no cleanup performed');
            $path=$dir.'/'.$name;clearstatcache(true,$path);$st=@lstat($path);if(!$st)throw new RuntimeException('file changed during scan');
            if(($st['mode']&0170000)===0120000)continue;
            if(preg_match('/[\x00-\x1f\x7f]/',$path)){$review[]='unsafe filename';continue;}
            if(($st['mode']&0170000)===0040000) {
                if(in_array($path,$nested,true)||in_array($name,['.git','.svn','.hg','node_modules','vendor','plugins','themes','.idea','.vscode','backup','backups','quarantine','evidence','wflogs'],true))continue;
                $isdev=in_array($name,['.pytest_cache','.mypy_cache','.sass-cache','__MACOSX','.AppleDouble'],true);
                if($isdev&&!$development)continue;
                $stack[]=[$path,$depth+1,$dev||$isdev];continue;
            }
            $ordinary=in_array($name,['.DS_Store','Thumbs.db','desktop.ini','.LSOverride'],true)||strpos($name,'._')===0;
            // Project/IDE settings are authored configuration, not disposable caches.
            $devFile=$development&&in_array($name,['.eslintcache','.stylelintcache','.phpunit.result.cache'],true);
            if($development&&($dev||$devFile)&&pg_cleanup_git_ancestor($path))continue;
            $rotated=$logs&&preg_match('/(?:\.log\.(?:[0-9]+|[0-9]{4}-[0-9]{2}-[0-9]{2})(?:\.gz)?|error_log\.[0-9]+)$/D',$name);
            if(!$ordinary&&!$rotated&&!$devFile&&!($development&&$dev))continue;
            if(($st['mode']&0170000)!==0100000||$st['nlink']!==1||$st['size']>67108864||$st['mtime']>$cutoff)continue;
            if(function_exists('posix_geteuid')&&$st['uid']!==posix_geteuid()){$review[]=$path.' (different owner)';continue;}
            if(pg_cleanup_nested($site,$path)){$review[]=$path.' (nested installation not in approved scope)';continue;}
            $bytes+=$st['size'];if($bytes>268435456)throw new RuntimeException('256 MiB candidate inspection budget reached; narrow the target');
            list($digest,$suspicious)=pg_cleanup_read($path,$st);
            if($suspicious){$review[]=$path.' (executable-like content; preserved for security review)';continue;}
            $item=['path'=>$path,'relative'=>substr($path,strlen($site)+1),'sha256'=>$digest];
            foreach(['dev','ino','size','mtime','ctime','mode','uid','gid','nlink'] as $key)$item[$key]=$st[$key];
            $items[]=$item;
            if(count($items)>1000)throw new RuntimeException('candidate limit reached; narrow the target before cleanup');
        }
    }
    return [$items,$review];
}
function pg_cleanup_validate($site,array $item) {
    if(!isset($item['path'],$item['relative'],$item['sha256'])||$item['path']!==$site.'/'.$item['relative']||
        pg_cleanup_nested($site,$item['path']))throw new RuntimeException('cleanup scope changed; regenerate preview');
    list($digest,$suspicious)=pg_cleanup_read($item['path'],$item);
    if($suspicious||!hash_equals($item['sha256'],$digest))throw new RuntimeException('candidate changed; regenerate preview');
}
/** Private per-invocation journal. Each removal gets before/after progress records. */
function pg_cleanup_manifest($file,array $data) {
    $json=json_encode($data,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES);
    if($json===false)throw new RuntimeException('cannot encode recovery manifest');
    if(file_exists($file)||is_link($file))pg_ops_regular($file,16777216);
    $tmp=$file.'.'.bin2hex(random_bytes(8)).'.tmp';$mask=umask(0077);$h=@fopen($tmp,'xb');umask($mask);
    if(!$h)throw new RuntimeException('cannot allocate recovery manifest');
    try {
        if(fwrite($h,$json)!==strlen($json)||!fflush($h))throw new RuntimeException('cannot write recovery manifest');
        if(function_exists('fsync')&&!fsync($h))throw new RuntimeException('cannot synchronize recovery manifest');
        fclose($h);$h=null;
        if(!rename($tmp,$file))throw new RuntimeException('cannot publish recovery manifest');
    } finally {if(is_resource($h))fclose($h);if(is_file($tmp))unlink($tmp);}
}
/** Internal in-memory plan only; never load an operator-supplied serialized plan. */
function pg_cleanup_execute_plan($state,$site,array $items) {
    if(!$items||count($items)>1000)throw new RuntimeException('invalid cleanup plan');
    pg_ops_scope($state,[$site]);
    foreach($items as $item)pg_cleanup_validate($site,$item);
    $backup=pg_ops_backup_dir($state,$site,'file-cleanup');$meta=$backup.'/manifest.json';
    $manifest=['source'=>$site,'files'=>$items,'status'=>'PREPARING'];
    pg_cleanup_manifest($meta,$manifest);
    echo 'Recovery copies and manifest: '.pg_cleanup_text($backup)."\n";
    try {
        // Verify every copy and original before deleting the first candidate.
        foreach($items as $i=>$item) {
            pg_cleanup_validate($site,$item);$dest=$backup.'/'.sprintf('%04d.data',$i);
            $in=@fopen($item['path'],'rb');$mask=umask(0077);$out=@fopen($dest,'xb');umask($mask);
            if(!$in||!$out){if(is_resource($in))fclose($in);if(is_resource($out))fclose($out);throw new RuntimeException('backup allocation failed');}
            try {
                if(!pg_cleanup_same($item,fstat($in)))throw new RuntimeException('source changed before backup');
                $copied=stream_copy_to_stream($in,$out,$item['size']+1);
                if($copied!==$item['size']||!fflush($out))throw new RuntimeException('backup incomplete');
                if(function_exists('fsync')&&!fsync($out))throw new RuntimeException('backup sync failed');
            } finally {fclose($in);fclose($out);}
            if(hash_file('sha256',$dest)!==$item['sha256'])throw new RuntimeException('backup checksum failed');
            pg_cleanup_validate($site,$item);$manifest['files'][$i]['backup']=basename($dest);
            $manifest['files'][$i]['result']='BACKED_UP';pg_cleanup_manifest($meta,$manifest);
        }
        $manifest['status']='BACKED_UP';pg_cleanup_manifest($meta,$manifest);
    } catch(Throwable $e) {
        $manifest['status']='BACKUP_FAILED_NOT_DELETED';pg_cleanup_manifest($meta,$manifest);throw $e;
    }
    $removed=0;$removedBytes=0;$failed=0;
    foreach($items as $i=>$item) {
        try {
            pg_cleanup_validate($site,$item);
            $manifest['status']='REMOVING';$manifest['files'][$i]['result']='PENDING_REMOVE';pg_cleanup_manifest($meta,$manifest);
            // Metadata is checked again after the journal write, immediately before unlink.
            clearstatcache(true,$item['path']);$now=pg_ops_regular($item['path'],67108864);
            if(!pg_cleanup_same($item,$now)||pg_cleanup_nested($site,$item['path']))throw new RuntimeException('source changed before unlink');
            if(!unlink($item['path']))throw new RuntimeException('unlink failed');
            clearstatcache(true,$item['path']);if(file_exists($item['path'])||is_link($item['path']))throw new RuntimeException('path still exists');
            $manifest['files'][$i]['result']='REMOVED';$removed++;$removedBytes+=$item['size'];pg_cleanup_manifest($meta,$manifest);
        }catch(Throwable $e){$manifest['files'][$i]['result']='UNVERIFIED_OR_UNCHANGED';$failed++;break;}
    }
    $manifest['status']=$failed?'PARTIAL':'COMPLETED';pg_cleanup_manifest($meta,$manifest);
    echo "Files removed: $removed; logical bytes removed: $removedBytes; errors: $failed\n";
    echo "Backups remain on disk; logical removed bytes are not a claim of net disk space reclaimed.\n";
    return $failed?2:0;
}
function pg_cleanup_run($action,$state,$site,$days,$logs,$dev,array $sites) {
    if(!in_array($action,['status','preview','execute'],true)||$days<1||$days>36500)throw new RuntimeException('invalid cleanup request');
    list($items,$review)=pg_cleanup_scan($site,$days,$logs,$dev,$sites);$bytes=array_sum(array_column($items,'size'));
    echo 'Selected WordPress path: '.pg_cleanup_text($site)."\n";
    echo 'Candidates: '.count($items)."; logical file bytes: $bytes; retained review items: ".count($review)."\n";
    foreach($items as $item)echo 'CANDIDATE '.pg_cleanup_text($item['relative']).' ('.$item['size']." bytes)\n";
    foreach(array_slice($review,0,20) as $text)echo 'REVIEW: '.pg_cleanup_text($text)."\n";
    if($action!=='execute'){echo "PREVIEW: no files changed. Current logs, project settings, links and protected recovery directories are excluded.\n";return $review?1:0;}
    if($review){echo "STOPPED: review items were detected; no cleanup performed.\n";return 2;}
    if(!$items){echo "UNCHANGED: no eligible files.\n";return 0;}
    if(getenv('PRESSGARDEN_INTERACTIVE')!=='0') {
        $tty=@fopen('/dev/tty','r+');
        if(!$tty){fwrite(STDERR,"Confirmation terminal required after preview; no site files changed.\n");return 1;}
        fwrite($tty,'Back up and remove exactly '.count($items).' previewed files under '.pg_cleanup_text($site).'? [y/N]: ');
        $answer=fgets($tty,32);fclose($tty);
        if(!in_array(strtolower(trim((string)$answer)),['y','yes'],true)){echo "DECLINED: no site files changed.\n";return 1;}
    }
    return pg_cleanup_execute_plan($state,$site,$items);
}
if(isset($argv[0])&&realpath($argv[0])===__FILE__) {
    try {
        if($argc!==9)throw new RuntimeException('invalid cleanup arguments');$sites=json_decode($argv[8],true);
        if(!is_array($sites))throw new RuntimeException('invalid site inventory');
        exit(pg_cleanup_run($argv[1],$argv[2],$argv[3],(int)$argv[4],$argv[5]==='1',$argv[6]==='1',$sites));
    }catch(Throwable $e){fwrite(STDERR,'CLEANUP INCOMPLETE: '.pg_cleanup_text($e->getMessage())."\n");exit(2);}
}
