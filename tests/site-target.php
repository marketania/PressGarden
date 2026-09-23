<?php
require __DIR__.'/../lib/site-target.php';
$n=0;function check($ok,$label){global $n;++$n;if(!$ok){fwrite(STDERR,"FAIL $label\n");exit(1);}}
foreach(['EXAMPLE.com'=>'example.com','https://Example.com/'=>'example.com','example.com/Shop'=>'example.com/Shop','https://example.com/shop/'=>'example.com/shop','www.example.com'=>'www.example.com','example.com./stage'=>'example.com/stage'] as $a=>$b)check(pg_site_name($a)===$b,'normalization '.$a);
foreach(['example.com?x=1','example.com/#secret','example.com:443','user:pass@example.com','example.com/../foo','example.com/./foo','example.com//foo','example.com/*','-example.com','example..com','example.com/$(id)',"example.com\nx",'ftp://example.com','example','/tmp/site'] as $bad)check(pg_site_name($bad)===null,'invalid name');
foreach([
 ['/home/domains/example.com/public_html','/home/domains','example.com'],
 ['/home/domains/example.com/public_html/shop','/home/domains','example.com/shop'],
 ['/var/www/vhosts/example.com/httpdocs','/var/www','example.com'],
 ['/var/www/example.com/htdocs','/var/www','example.com'],
 ['/var/www/example.com','/var/www','example.com'],
 ['/home/example.com/public_html','/home/example.com/public_html','example.com'],
 ['/var/www/opaque','/var/www',null],
 ['/var/www/example.com/httpdocs/stage_2','/var/www','example.com/stage_2'],
] as [$site,$scope,$want])check(pg_site_directory_name($site,$scope)===$want,'hosting layout');
printf("Site-name parser: %d assertions PASS\n",$n);
