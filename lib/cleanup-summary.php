<?php
/** Validate internal preview records before rendering any provider output. */
require_once __DIR__.'/ops-safety.php';
function pg_summary_text($text) {return preg_replace('/[\p{Cc}\p{Cf}]/u','?', $text)??'(unreadable text)';}
try {
    if($argc!==3||!in_array($argv[1],['files','files-details','db'],true))throw new RuntimeException('invalid summary request');
    pg_ops_regular($argv[2],1048576);$raw=file_get_contents($argv[2]);
    $data=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
    if(!is_array($data))throw new RuntimeException('invalid summary');
    if($argv[1]==='db') {
        if(array_keys($data)!==['format','expired','revisions']||$data['format']!=='PGDBCL1')throw new RuntimeException('invalid database summary');
        foreach(['expired','revisions'] as $k)if(!is_int($data[$k])||$data[$k]<0||$data[$k]>1000000000)throw new RuntimeException('invalid database count');
        if($data['revisions']>1001)throw new RuntimeException('invalid revision count');
        echo $data['expired'],"\t",$data['revisions'],"\n";
    }else {
        if(array_keys($data)!==['format','files','bytes','review','items','reviews']||$data['format']!=='PGCLEAN1')throw new RuntimeException('invalid file summary');
        foreach(['files','bytes','review'] as $k)if(!is_int($data[$k])||$data[$k]<0)throw new RuntimeException('invalid file count');
        if(!is_array($data['items'])||!is_array($data['reviews'])||$data['files']!==count($data['items'])||$data['files']>1000||$data['bytes']>268435456||count($data['reviews'])>20)throw new RuntimeException('invalid file details');
        $bytes=0;foreach($data['items'] as $item) {
            if(!is_array($item)||array_keys($item)!==['path','bytes']||!is_string($item['path'])||strlen($item['path'])>8192||!is_int($item['bytes'])||$item['bytes']<0||$item['bytes']>67108864)throw new RuntimeException('invalid file item');
            $bytes+=$item['bytes'];
        }
        if($bytes!==$data['bytes'])throw new RuntimeException('inconsistent file bytes');
        foreach($data['reviews'] as $review)if(!is_string($review)||strlen($review)>16384)throw new RuntimeException('invalid review text');
        if($argv[1]==='files')echo $data['files'],"\t",$data['bytes'],"\t",$data['review'],"\n";
        else {
            foreach(array_slice($data['items'],0,100) as $item)echo '    CANDIDATE ',pg_summary_text($item['path']),' (',$item['bytes']," bytes)\n";
            if($data['files']>100)echo "    Showing the first 100 candidates; execution previews the full selected file plan.\n";
            foreach($data['reviews'] as $review)echo '    REVIEW: ',pg_summary_text($review),"\n";
            if($data['review']>20)echo "    Showing the first 20 retained review items.\n";
        }
    }
}catch(Throwable $e){fwrite(STDERR,"INCOMPLETE: preview response could not be verified.\n");exit(2);}
