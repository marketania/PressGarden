<?php
// Unit/contract fixtures only. No real WordPress site/database is reachable.
define('PG_DATABASE_TEST',true);define('ARRAY_A','ARRAY_A');require __DIR__.'/../lib/database.php';
$n=0;function check($ok,$label){global $n;$n++;if(!$ok)throw new RuntimeException($label);}
foreach(['OK'=>'OK','Table is already up to date'=>'OK',"The storage engine for the table doesn't support check"=>'UNSUPPORTED','Table is marked as crashed'=>'CORRUPT'] as $text=>$want)check(pg_db_result([['Msg_type'=>'status','Msg_text'=>$text]])===$want,'result '.$text);
check(pg_db_result([])==='UNVERIFIED','missing result');check(pg_db_result([['Msg_type'=>'error','Msg_text'=>'permission denied']])==='ERROR','query errors not corruption');
foreach(['wp_posts;DROP','wp_posts`','other.table','../wp_posts'] as $name){$caught=false;try{pg_db_identifier($name);}catch(Throwable $e){$caught=true;}check($caught,'identifier refusal');}
function is_multisite(){return $GLOBALS['multi']??false;}
function get_site($id){return $id===2?(object)['blog_id'=>2]:null;}
function switch_to_blog($id){$GLOBALS['wpdb']->prefix='wp_'.$id.'_';}
function get_post($id){return (object)['post_type'=>'revision','post_modified_gmt'=>'2000-01-01 00:00:00'];}function wp_delete_post($id,$force){return (object)['ID'=>$id];}
class FixtureDB {
 public $last_error='',$prefix='wp_',$options='wp_options',$posts='wp_posts';public $sql=[],$state='OK',$engine='InnoDB',$expired=2;
 function tables($scope,$prefix){return ['posts'=>'wp_posts','options'=>'wp_options'];}
 function esc_like($s){return addcslashes($s,'_%\\');}
 function prepare($sql,...$args){foreach($args as $arg){$sql=preg_replace('/%[sd]/',is_int($arg)?(string)$arg:"'".str_replace("'","''",$arg)."'",$sql,1);}return $sql;}
 function get_results($sql,$fmt){$this->sql[]=$sql;
  if(strpos($sql,'information_schema')!==false){$r=[];foreach(['wp_options','wp_posts','foreign_data','wp_custom'] as $name)$r[]=['TABLE_NAME'=>$name,'ENGINE'=>$this->engine,'DATA_LENGTH'=>1024,'INDEX_LENGTH'=>512,'DATA_FREE'=>0];return $r;}
  if(strpos($sql,'CHECK TABLE')===0)return [['Msg_type'=>'status','Msg_text'=>$this->state]];
  if(strpos($sql,'OPTIMIZE TABLE')===0||strpos($sql,'REPAIR TABLE')===0)return [['Msg_type'=>'status','Msg_text'=>'OK']];
  if(strpos($sql,'COUNT(*)')!==false)return [['n'=>$this->expired]];
  if(strpos($sql,'SELECT ID')===0)return [['ID'=>7]];
  throw new RuntimeException('unexpected SQL in fixture');
 }
 function query($sql){$this->sql[]=$sql;if(strpos($sql,'DELETE a,b')===0){$this->expired=0;return 4;}throw new RuntimeException('unexpected mutation');}
}
$wpdb=new FixtureDB();$scope=pg_db_scope('','');check(array_keys($scope)===['wp_options','wp_posts'],'registered tables only');check(count(pg_db_scope('wp_custom',''))===1,'explicit plugin table');
$caught=false;try{pg_db_scope('foreign_data','');}catch(Throwable $e){$caught=true;}check($caught,'foreign DB table isolation');
function run($action,$execute='0',$revisions='0') {ob_start();$rc=pg_db_run([$action,'','',''.$execute,$revisions,'30','']);$text=ob_get_clean();return [$rc,$text];}
$wpdb->sql=[];list($rc,$text)=run('check');check($rc===0,'check success');check(!preg_grep('/^(?:REPAIR|OPTIMIZE|DELETE)/',$wpdb->sql),'check never mutates');
$wpdb->state="The storage engine for the table doesn't support check";list($rc,$text)=run('check');check($rc===0&&strpos($text,'UNSUPPORTED')!==false,'engine limits are informational');
$wpdb->state='OK';$wpdb->sql=[];list($rc,$text)=run('optimize','1');check($rc===0&&substr_count($text,'VERIFIED OPTIMIZE')===2,'optimize and postcheck');
$wpdb->state='Table is marked as crashed';$wpdb->sql=[];list($rc,$text)=run('optimize','1');check($rc===2&&!preg_grep('/^OPTIMIZE/',$wpdb->sql),'corruption prevents optimization');
$wpdb->sql=[];list($rc,$text)=run('repair','1');check($rc===2&&!preg_grep('/^REPAIR/',$wpdb->sql),'InnoDB repair never invented');
$wpdb->state='OK';$wpdb->sql=[];list($rc,$text)=run('cleanup');check($rc===0&&!preg_grep('/^DELETE/',$wpdb->sql),'cleanup defaults preview');
list($rc,$text)=run('cleanup','1','1');check($rc===0&&strpos($text,'affected-row count): 4')!==false,'cleanup affected rows');
$caught=false;try{pg_db_run(['optimize','','','1','0','30','bad-plan']);}catch(Throwable $e){$caught=true;}check($caught,'table plan mismatch prevents mutation');
$multi=true;$caught=false;try{pg_db_scope('','');}catch(Throwable $e){$caught=true;}check($caught,'multisite requires explicit blog');
echo "Native DB contract: $n assertions PASS\n";
