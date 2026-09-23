<?php
/** Scoped native database operations, invoked by WP-CLI eval-file. PHP >=7.4. */
function pg_db_identifier($name) {
    if(!is_string($name)||!preg_match('/^[A-Za-z0-9_]{1,64}$/D',$name))throw new RuntimeException('unsafe SQL identifier');
    return '`'.$name.'`';
}
function pg_db_result(array $rows) {
    $ok=false;$unsupported=false;$corrupt=false;$error=false;
    foreach($rows as $r){$text=strtolower((string)($r['Msg_text']??''));$type=strtolower((string)($r['Msg_type']??''));
        if(preg_match('/doesn.t support|not support|not implemented/',$text)){$unsupported=true;continue;}
        if(preg_match('/corrupt|crashed|marked as crashed/',$text))$corrupt=true;
        if($type==='error')$error=true;
        if($type==='status'&&in_array($text,['ok','table is already up to date'],true))$ok=true;
    }
    if($corrupt)return 'CORRUPT';if($error)return 'ERROR';if($ok)return 'OK';if($unsupported)return 'UNSUPPORTED';return 'UNVERIFIED';
}
function pg_db_query($sql) {
    global $wpdb;$wpdb->last_error='';$out=$wpdb->query($sql);
    if($out===false||$wpdb->last_error!=='')throw new RuntimeException('database query failed; no success inferred');return $out;
}
function pg_db_rows($sql) {
    global $wpdb;$wpdb->last_error='';$out=$wpdb->get_results($sql,ARRAY_A);
    if(!is_array($out)||$wpdb->last_error!=='')throw new RuntimeException('database read failed');return $out;
}
function pg_db_scope($tables,$blog) {
    global $wpdb;
    if(is_multisite()) {
        if(!preg_match('/^[1-9][0-9]*$/D',$blog)||!get_site((int)$blog))throw new RuntimeException('multisite requires an existing explicit --blog=ID; no implicit network-wide action');
        switch_to_blog((int)$blog);
        $registered=$wpdb->tables('blog',true);
    }else {
        if($blog!==''&&$blog!=='1')throw new RuntimeException('blog selection not valid for this single site');
        $registered=$wpdb->tables('all',true);
    }
    $available=pg_db_rows("SELECT TABLE_NAME, ENGINE, DATA_LENGTH, INDEX_LENGTH, DATA_FREE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'");
    $map=[];foreach($available as $t){if(!isset($t['TABLE_NAME']))throw new RuntimeException('invalid table inventory');$map[$t['TABLE_NAME']]=$t;}
    $wanted=$tables===''?array_values($registered):explode(',',$tables);
    $out=[];$prefix=$wpdb->prefix;
    foreach(array_unique($wanted) as $name) {
        pg_db_identifier($name);
        if(strpos($name,$prefix)!==0)throw new RuntimeException('requested table is outside selected WordPress prefix');
        if(is_multisite()&&preg_match('/^'.preg_quote($prefix,'/').'[0-9]+_/',$name))throw new RuntimeException('requested table belongs to another blog');
        if(!isset($map[$name])) {
            if($tables!=='')throw new RuntimeException('explicit table is missing or not a base table');
            continue;
        }
        $out[$name]=$map[$name];
    }
    if(!$out)throw new RuntimeException('no selected WordPress tables');ksort($out);return $out;
}
function pg_db_allocation(array $tables){$n=0;foreach($tables as $t)$n+=(int)$t['DATA_LENGTH']+(int)$t['INDEX_LENGTH'];return $n;}
function pg_db_expired_count($options) {
    global $wpdb;$rows=pg_db_rows($wpdb->prepare('SELECT COUNT(*) AS n FROM '.pg_db_identifier($options).' WHERE option_name LIKE %s AND CAST(option_value AS UNSIGNED) > 0 AND CAST(option_value AS UNSIGNED) < %d',$wpdb->esc_like('_transient_timeout_').'%',time()));return (int)$rows[0]['n'];
}
function pg_db_cleanup(array $scope,$execute,$revisions,$days) {
    global $wpdb;$options=$wpdb->options;$posts=$wpdb->posts;
    if(!isset($scope[$options]))throw new RuntimeException('cleanup requires the selected options table');
    $expired=pg_db_expired_count($options);$candidates=[];
    if($revisions) {
        if(!isset($scope[$posts]))throw new RuntimeException('revision cleanup requires the selected posts table');
        $candidates=pg_db_rows($wpdb->prepare('SELECT ID FROM '.pg_db_identifier($posts).' WHERE post_type=%s AND post_modified_gmt < %s ORDER BY ID LIMIT 1001','revision',gmdate('Y-m-d H:i:s',time()-$days*86400)));
    }
    echo "Expired transient timeout rows observed: $expired\n";
    echo 'Eligible revision candidates observed (bounded at 1001): '.count($candidates)."\n";
    if(!$execute){echo "PREVIEW ONLY: no database rows changed. Add --execute, and --revisions only to request revision deletion.\n";return 0;}
    $affected=pg_db_query($wpdb->prepare('DELETE a,b FROM '.pg_db_identifier($options).' a INNER JOIN '.pg_db_identifier($options).' b ON b.option_name=CONCAT(%s,SUBSTRING(a.option_name,12)) WHERE a.option_name LIKE %s AND b.option_value > 0 AND b.option_value < %d','_transient_timeout_',$wpdb->esc_like('_transient_').'%',time()));
    $removed=0;$failed=0;
    foreach(array_slice($candidates,0,1000) as $row){$id=(int)$row['ID'];$post=get_post($id);if(!$post||$post->post_type!=='revision'||$post->post_modified_gmt>=gmdate('Y-m-d H:i:s',time()-$days*86400)){$failed++;continue;}if(wp_delete_post($id,true))$removed++;else $failed++;}
    echo "Expired transient option rows deleted (database affected-row count): $affected\n";
    echo "Revisions deleted (successful API deletions): $removed\n";
    $after=pg_db_expired_count($options);echo "Expired timeout rows remaining: $after\n";
    if(count($candidates)>1000){echo "PARTIAL: revision batch limit reached; review before another invocation.\n";return 1;}
    if($failed||$after){echo "PARTIAL: requested cleanup not fully verified; concurrent writes may affect counts.\n";return 1;}return 0;
}
function pg_db_run(array $args) {
    global $wpdb;
    if(count($args)!==7)throw new RuntimeException('invalid database operation arguments');
    list($action,$tables,$blog,$execute,$revisions,$days,$expected)=$args;
    if(!in_array($action,['plan','status','check','repair','optimize','cleanup'],true))throw new RuntimeException('unknown database action');
    if(!preg_match('/^[1-9][0-9]{0,4}$/D',$days))throw new RuntimeException('invalid retention days');
    $scope=pg_db_scope($tables,$blog);$csv=implode(',',array_keys($scope));
    if($action==='plan'){echo $csv,"\n";return 0;}
    if($expected!==''&&!hash_equals($expected,hash('sha256',$csv)))throw new RuntimeException('table scope changed after preflight; operation refused');
    echo 'Selected tables: '.count($scope)."\n";$before=pg_db_allocation($scope);
    echo "Selected allocation before (engine estimate, bytes): $before\n";
    if($action==='status'){foreach($scope as $name=>$t)echo $name.' | '.$t['ENGINE'].' | overhead estimate '.(int)$t['DATA_FREE']." bytes\n";echo "Status inventories storage; it is not a corruption check.\n";return 0;}
    if($action==='cleanup')return pg_db_cleanup($scope,$execute==='1',$revisions==='1',(int)$days);
    if(in_array($action,['repair','optimize'],true)&&$execute!=='1')throw new RuntimeException('mutation gate missing');
    $checked=0;$changed=0;$skipped=0;$failed=0;
    foreach($scope as $name=>$table) {
        $id=pg_db_identifier($name);
        $state=pg_db_result(pg_db_rows('CHECK TABLE '.$id));$checked++;
        if($action==='check'){echo "$name | CHECK $state\n";if(!in_array($state,['OK','UNSUPPORTED'],true))$failed++;continue;}
        if(in_array($state,['ERROR','UNVERIFIED'],true)){echo "$name | SKIPPED: check incomplete; $state\n";$failed++;continue;}
        if($action==='optimize'&&$state!=='OK'){echo "$name | SKIPPED: optimize requires a successful check, observed $state\n";if($state==='CORRUPT')$failed++;else $skipped++;continue;}
        if($action==='repair') {
            if(!in_array(strtoupper((string)$table['ENGINE']),['MYISAM','ARCHIVE','CSV'],true)) {echo "$name | REPAIR UNSUPPORTED for {$table['ENGINE']} (not a corruption finding)\n";$skipped++;if($state==='CORRUPT')$failed++;continue;}
            if($state==='OK'){echo "$name | UNCHANGED: check OK; repair unnecessary\n";$skipped++;continue;}
        }
        $result=pg_db_result(pg_db_rows(strtoupper($action).' TABLE '.$id));
        if($result==='UNSUPPORTED'){echo "$name | ".strtoupper($action)." UNSUPPORTED\n";$skipped++;continue;}
        if($result!=='OK'){echo "$name | FAILED: operation $result\n";$failed++;continue;}
        $post=pg_db_result(pg_db_rows('CHECK TABLE '.$id));
        if($post!=='OK'){echo "$name | UNVERIFIED: post-operation check $post\n";$failed++;continue;}
        $changed++;echo "$name | VERIFIED ".strtoupper($action)."; CHECK OK\n";
    }
    $after=pg_db_allocation(pg_db_scope($csv,$blog));
    echo "Tables checked: $checked; verified $action operations: $changed; skipped: $skipped; errors: $failed\n";
    echo "Selected allocation after (engine estimate, bytes): $after\n";
    echo 'Net allocation decrease (estimate, not proven reclaimed disk bytes): '.($before-$after)."\n";
    return $failed?2:0;
}
if(!defined('PG_DATABASE_TEST')) {
    try {exit(pg_db_run($args??[]));}
    catch(Throwable $e){fwrite(STDERR,'DATABASE INCOMPLETE: '.$e->getMessage()."\n");exit(2);}
}
