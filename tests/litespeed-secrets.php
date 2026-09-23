<?php
define('PG_LITESPEED_SECRET_TEST',true);require __DIR__.'/../lib/litespeed-secret-command.php';
class WP_CLI {public static $call;static function run_command($args,$assoc){self::$call=[$args,$assoc];}}
putenv('PG_FIXTURE_SECRET=fixture-only-token');ob_start();pg_litespeed_secret_command(['link','api-key','PG_FIXTURE_SECRET','email=fixture@example.invalid']);$out=ob_get_clean();
if($out!==''||WP_CLI::$call[0]!==['litespeed-online','link']||WP_CLI::$call[1]['api-key']!=='fixture-only-token')throw new RuntimeException('private dispatch contract');
foreach([['purge','api-key','PG_FIXTURE_SECRET'],['link','cf-token','PG_FIXTURE_SECRET'],['link','api-key',''],['link','api-key','PG_FIXTURE_SECRET','api-key=literal']]as$args){$caught=false;try{pg_litespeed_secret_command($args);}catch(Throwable$e){$caught=true;}if(!$caught)throw new RuntimeException('unsafe argument accepted');}
putenv('PG_FIXTURE_SECRET');echo "LiteSpeed private in-process credential dispatch: 5 assertions PASS\n";
