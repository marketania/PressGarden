<?php
/** Inert table inventory: no database connection and no writes. */
define('PG_DATABASE_TEST', true); define('ARRAY_A', 'ARRAY_A');
require __DIR__.'/../lib/database.php';
function is_multisite(){return $GLOBALS['multi'];}
function get_site($id){return in_array($id,[1,2],true)?(object)['blog_id'=>$id]:null;}
function switch_to_blog($id){$GLOBALS['wpdb']->prefix=$id===1?'wp_':'wp_'.$id.'_';}
class ScopeInventory {
    public $prefix='wp_', $last_error='', $reads=0;
    function tables($scope,$prefix){
        $blog=['posts'=>$this->prefix.'posts','options'=>$this->prefix.'options'];
        $global=['users'=>'wp_users','usermeta'=>'wp_usermeta','blogs'=>'wp_blogs','sitemeta'=>'wp_sitemeta','custom_users'=>'wp_shared_users'];
        if($scope==='global')return $global;
        return $scope==='all'?array_merge($blog,$global):$blog;
    }
    function get_results($sql,$format){
        if(strpos($sql,'SELECT TABLE_NAME, ENGINE')!==0)throw new RuntimeException('Unexpected query');
        $this->reads++;
        return array_map(function($name){return ['TABLE_NAME'=>$name,'ENGINE'=>'InnoDB','DATA_LENGTH'=>1,'INDEX_LENGTH'=>1,'DATA_FREE'=>0];},
            ['wp_posts','wp_options','wp_users','wp_usermeta','wp_blogs','wp_sitemeta','wp_shared_users','wp_plugin','wp_2_posts','wp_2_options','wp_2_plugin']);
    }
}
$wpdb=new ScopeInventory();$multi=true;$checks=0;
function scope_check($value,$message){global $checks;$checks++;if(!$value)throw new RuntimeException($message);}
foreach(['wp_users','wp_usermeta','wp_blogs','wp_sitemeta','wp_shared_users','wp_options,wp_users'] as $tables){
    $refused=false;try{pg_db_scope($tables,'1');}catch(Throwable $e){$refused=strpos($e->getMessage(),'network-global')!==false;}
    scope_check($refused,'primary blog accepted network-global tables');
}
scope_check(array_keys(pg_db_scope('','1'))===['wp_options','wp_posts'],'primary registered blog tables changed');
scope_check(array_keys(pg_db_scope('wp_plugin','1'))===['wp_plugin'],'explicit owned plugin table refused');
scope_check(array_keys(pg_db_scope('','2'))===['wp_2_options','wp_2_posts'],'second blog registered tables changed');
scope_check(array_keys(pg_db_scope('wp_2_plugin','2'))===['wp_2_plugin'],'second blog plugin table refused');
foreach([['wp_2_posts','1'],['wp_posts','2'],['wp_users','2'],['wp_missing','1'],['wp_posts','0'],['wp_posts','999']] as $case){
    $refused=false;try{pg_db_scope($case[0],$case[1]);}catch(Throwable $e){$refused=true;}
    scope_check($refused,'foreign/missing/invalid blog scope accepted');
}
$multi=false;$wpdb->prefix='wp_';
scope_check(isset(pg_db_scope('','')['wp_users']),'ordinary single-site registered user table regressed');
echo "Database scope: $checks assertions PASS; no SQL mutation adapter exists.\n";
