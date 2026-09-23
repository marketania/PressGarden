<?php
/** Keep QUIC.cloud/Cloudflare credentials out of operating-system command arguments. */
function pg_litespeed_secret_command(array $params){
    if(count($params)<3)throw new RuntimeException('invalid private provider invocation');
    list($action,$field,$env)=$params;
    if(($action==='link'&&$field!=='api-key')||($action==='cdn_init'&&$field!=='cf-token')||!in_array($action,['link','cdn_init'],true))throw new RuntimeException('unsupported private provider invocation');
    if(!preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/D',$env))throw new RuntimeException('invalid environment reference');
    $secret=getenv($env);if(!is_string($secret)||$secret===''||strlen($secret)>8192)throw new RuntimeException('missing/oversized provider credential');
    $allowed=$action==='link'?['email']:['method','ssl-cert','ssl-key'];$assoc=[];
    foreach(array_slice($params,3)as$param){$pair=explode('=',$param,2);if(count($pair)!==2||!in_array($pair[0],$allowed,true)||isset($assoc[$pair[0]]))throw new RuntimeException('invalid provider option');$assoc[$pair[0]]=$pair[1];}
    $assoc[$field]=$secret;
    // Official in-process WP-CLI API: no shell/new process receives the secret.
    WP_CLI::run_command(['litespeed-online',$action],$assoc);
}
if(!defined('PG_LITESPEED_SECRET_TEST')){
    try{pg_litespeed_secret_command($args??[]);}
    catch(Throwable $e){fwrite(STDERR,"Private LiteSpeed provider invocation failed; response withheld.\n");exit(2);}
}
