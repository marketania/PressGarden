<?php
/** Conservative, bounded file cleanup. No malware removal and no live log truncation. */
require_once __DIR__.'/ops-safety.php';
function pg_cleanup_git_ancestor($path) {
    $dir=dirname($path);while($dir!=='/'&&$dir!=='.'){
        if(file_exists($dir.'/.git')||is_link($dir.'/.git'))return true;
        $parent=dirname($dir);if($parent===$dir)break;$dir=$parent;
    }return false;
}
function pg_cleanup_scan($site,$days,$logs,$development,array $sites) {
    pg_ops_path($site);$cutoff=time()-$days*86400;$stack=[[$site,0,false]];$items=[];$review=[];$seen=0;
    $nested=array_filter($sites,function($p)use($site){return $p!==$site&&strpos($p,$site.'/')===0;});
    while($stack) {
        list($dir,$depth,$dev)=array_pop($stack);
        if($depth>24)throw new RuntimeException('scan depth limit reached; no cleanup performed');
        pg_ops_path($dir);$entries=@scandir($dir);
        if($entries===false)throw new RuntimeException('incomplete directory scan; no cleanup performed');
        foreach($entries as $name){if($name==='.'||$name==='..')continue;
            if(++$seen>200000)throw new RuntimeException('scan entry limit reached; no cleanup performed');
            $path=$dir.'/'.$name;$st=@lstat($path);if(!$st)throw new RuntimeException('file changed during scan');
            if(is_link($path))continue;
            if(preg_match('/[\x00-\x1f\x7f]/',$path)){$review[]='unsafe filename';continue;}
            if(is_dir($path)) {
                if(in_array($path,$nested,true)||in_array($name,['.git','.svn','.hg','node_modules','vendor','plugins','themes'],true))continue;
                $isdev=in_array($name,['.idea','.vscode','.pytest_cache','.mypy_cache','.sass-cache','__MACOSX','.AppleDouble'],true);
                if($isdev&&!$development)continue;
                $stack[]=[$path,$depth+1,$dev||$isdev];continue;
            }
            $ordinary=in_array($name,['.DS_Store','Thumbs.db','desktop.ini','.LSOverride'],true)||strpos($name,'._')===0;
            $devFile=$development&&in_array($name,['.gitignore','.gitattributes','.gitkeep','.editorconfig','.eslintignore','.stylelintignore','.prettierignore','.npmignore','phpcs.xml','phpcs.xml.dist','.phpcs.xml','.phpcs.xml.dist','phpstan.neon','phpstan.neon.dist','.prettierrc','.prettierrc.json','.eslintrc','.eslintrc.json','.stylelintrc','.stylelintrc.json','phpunit.xml','phpunit.xml.dist','.eslintcache','.stylelintcache','.phpunit.result.cache'],true);
            if($development&&($dev||$devFile)&&pg_cleanup_git_ancestor($path))continue;
            $rotated=$logs&&preg_match('/(?:\.log\.(?:[0-9]+|[0-9]{4}-[0-9]{2}-[0-9]{2})(?:\.gz)?|error_log\.[0-9]+)$/D',$name);
            if(!$ordinary&&!$rotated&&!$devFile&&!($development&&$dev))continue;
            if(($st['mode']&0170000)!==0100000||$st['nlink']!==1||$st['size']>67108864||$st['mtime']>$cutoff){continue;}
            if(function_exists('posix_geteuid')&&$st['uid']!==posix_geteuid()){$review[]=$path.' (different owner)';continue;}
            $h=@fopen($path,'rb');if(!$h)throw new RuntimeException('unreadable cleanup candidate');$prefix=fread($h,65536);fclose($h);
            if($prefix===false)throw new RuntimeException('cannot inspect cleanup candidate');
            if(preg_match('/<\?(?:php|=)|^#!|<script\b|\b(?:eval|base64_decode|shell_exec)\s*\(/i',$prefix)){$review[]=$path.' (executable-like content; preserved for security review)';continue;}
            $items[]=['path'=>$path,'relative'=>substr($path,strlen($site)+1),'size'=>$st['size'],'mtime'=>$st['mtime'],'dev'=>$st['dev'],'ino'=>$st['ino'],'sha256'=>hash_file('sha256',$path)];
            if(count($items)>1000)throw new RuntimeException('candidate limit reached; narrow the target before cleanup');
        }
    }
    return [$items,$review];
}
function pg_cleanup_run($action,$state,$site,$days,$logs,$dev,array $sites) {
    if(!in_array($action,['status','preview','execute'],true)||$days<1||$days>36500)throw new RuntimeException('invalid cleanup request');
    list($items,$review)=pg_cleanup_scan($site,$days,$logs,$dev,$sites);
    $bytes=array_sum(array_column($items,'size'));
    echo 'Candidates: '.count($items)."; logical file bytes: $bytes; retained review items: ".count($review)."\n";
    foreach($items as $item)echo 'CANDIDATE '.$item['relative'].' ('.$item['size']." bytes)\n";
    foreach(array_slice($review,0,20) as $text)echo 'REVIEW: '.$text."\n";
    if($action!=='execute'){echo "PREVIEW: no files changed. Current logs, application code, symlinks and security evidence are not routine cleanup targets.\n";return $review?1:0;}
    if($review){echo "STOPPED: review items were detected; no cleanup performed.\n";return 2;}
    if(!$items){echo "UNCHANGED: no eligible files.\n";return 0;}
    $backup=pg_ops_backup_dir($state,$site,'file-cleanup');$manifest=['source'=>$site,'files'=>$items,'status'=>'PREPARING'];
    // Back up and verify every candidate before deleting the first one.
    foreach($items as $i=>$item) {
        pg_ops_regular($item['path'],67108864);$dest=$backup.'/'.sprintf('%04d.data',$i);
        $in=fopen($item['path'],'rb');$out=fopen($dest,'xb');if(!$in||!$out)throw new RuntimeException('backup allocation failed');
        $copied=stream_copy_to_stream($in,$out);fclose($in);fclose($out);chmod($dest,0600);
        clearstatcache();$now=pg_ops_regular($item['path'],67108864);
        if($copied!==$item['size']||$now['ino']!==$item['ino']||$now['dev']!==$item['dev']||hash_file('sha256',$dest)!==$item['sha256']||hash_file('sha256',$item['path'])!==$item['sha256'])throw new RuntimeException('candidate changed while backing up; nothing deleted');
        $manifest['files'][$i]['backup']=basename($dest);
    }
    $manifest['status']='BACKED_UP';$meta=$backup.'/manifest.json';
    if(file_put_contents($meta,json_encode($manifest,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES))===false)throw new RuntimeException('backup manifest write failed');chmod($meta,0600);
    $removed=0;$removedBytes=0;$failed=0;
    foreach($items as $i=>$item) {
        try {
            clearstatcache();$now=pg_ops_regular($item['path'],67108864);
            if($now['ino']!==$item['ino']||$now['dev']!==$item['dev']||hash_file('sha256',$item['path'])!==$item['sha256'])throw new RuntimeException('source changed');
            if(!unlink($item['path']))throw new RuntimeException('unlink failed');
            clearstatcache();if(file_exists($item['path'])||is_link($item['path']))throw new RuntimeException('path still exists');
            $manifest['files'][$i]['result']='REMOVED';$removed++;$removedBytes+=$item['size'];
        }catch(Throwable $e){$manifest['files'][$i]['result']='UNVERIFIED_OR_UNCHANGED';$failed++;break;}
    }
    $manifest['status']=$failed?'PARTIAL':'COMPLETED';
    if(file_put_contents($meta,json_encode($manifest,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES))===false)$failed++;
    echo "Files removed: $removed; logical bytes removed: $removedBytes; errors: $failed\n";
    echo "Recovery copies and manifest: $backup\n";
    echo "Backups remain on disk; logical removed bytes are not a claim of net disk space reclaimed.\n";
    return $failed?2:0;
}
if(isset($argv[0])&&realpath($argv[0])===__FILE__) {
    try {
        if($argc!==9)throw new RuntimeException('invalid cleanup arguments');$sites=json_decode($argv[8],true);
        if(!is_array($sites))throw new RuntimeException('invalid site inventory');
        exit(pg_cleanup_run($argv[1],$argv[2],$argv[3],(int)$argv[4],$argv[5]==='1',$argv[6]==='1',$sites));
    }catch(Throwable $e){fwrite(STDERR,'CLEANUP INCOMPLETE: '.$e->getMessage()."\n");exit(2);}
}
