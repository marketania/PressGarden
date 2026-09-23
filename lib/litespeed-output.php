<?php
// Readback normalization follows LiteSpeed CLI get: booleans 1/0, empty scalar ''.
function pg_ls_sensitive($key){return preg_match('/api.?key|domain.?key|token|secret|password|passwd|private.?key|ssl.?key|credential|authorization|cookie/i',(string)$key);}
function pg_ls_redact($value) {
    if(!is_array($value))return $value;
    $out=[];foreach($value as $k=>$v){$out[$k]=pg_ls_sensitive($k)?'[REDACTED]':pg_ls_redact($v);}return $out;
}
try {
    $mode=$argv[1]??'';
    if($mode==='verify') {
        $expected=stream_get_contents(STDIN,1048577);$actual=file_get_contents($argv[2]);
        if($actual===false||strlen($actual)>1048576||strlen($expected)>1048576)exit(2);
        $actual=rtrim(str_replace("\r\n","\n",$actual),"\n");$expected=rtrim(str_replace("\r\n","\n",$expected),"\n");
        if(in_array($expected,['true','false'],true)){$expected=$expected==='true'?'1':'0';if($actual==='true')$actual='1';if($actual==='false')$actual='0';}
        if($expected===''&&$actual==="''")$actual='';
        exit(hash_equals($expected,$actual)?0:2);
    }
    if($mode!=='redact')exit(2);
    $text=stream_get_contents(STDIN,4194305);
    if(strlen($text)>4194304){echo "[Response too large; withheld]\n";exit(2);}
    $parsed=json_decode($text,true);
    if(is_array($parsed)){echo json_encode(pg_ls_redact($parsed),JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES),"\n";exit(0);}
    foreach(explode("\n",$text) as $line){if(pg_ls_sensitive($line))echo "[REDACTED sensitive response line]\n";else echo $line,"\n";}
}catch(Throwable $e){fwrite(STDERR,"Provider output verification failed; response suppressed.\n");exit(2);}
