<?php
/** Validate the original directory spelling before realpath can hide symlinks. */
try {
    if($argc!==3)throw new RuntimeException('invalid path check');
    $p=$argv[2];if($p==='')exit(0);
    if(preg_match('/[\x00-\x1f\x7f]/',$p))throw new RuntimeException('control character in target');
    if($p[0]!=='/')$p=rtrim($argv[1],'/').'/'.$p;
    $parts=[];
    foreach(explode('/',$p) as $part){
        if($part===''||$part==='.')continue;
        if($part==='..'){array_pop($parts);continue;}
        $parts[]=$part;$cur='/'.implode('/',$parts);
        if(is_link($cur))throw new RuntimeException('symlink target component refused');
        if(file_exists($cur)&&!is_dir($cur))throw new RuntimeException('non-directory target component refused');
    }
}catch(Throwable $e){fwrite(STDERR,'TARGET: '.$e->getMessage()."\n");exit(2);}
