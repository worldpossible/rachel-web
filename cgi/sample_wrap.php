<?php
    if (isset($_GET['moddir'])) {
        $moddir = preg_replace("/[^\w\-]/", "", $_GET['moddir']);
    }
    if (!isset($moddir)) {
        header ("HTTP/1.1 404 Not Found");
        echo "404 - Not Found";
        exit;
    }
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title></title>
    <link rel="stylesheet" href="/sample_assets/css/normalize-1.1.3.css">
    <link rel="stylesheet" href="/sample_assets/css/style.css">
    <link rel="stylesheet" href="/sample_assets/css/ui-lightness/jquery-ui-1.10.4.custom.min.css">
    <script src="/sample_assets/js/jquery-1.10.2.min.js"></script>
    <script src="/sample_assets/js/jquery-ui-1.10.4.custom.min.js"></script>
    <script>
        $(function() {
            $("#<?php echo $moddir ?>_search").autocomplete({ source: "/mods/<?php echo $moddir ?>/search/suggest.php", });
        });
    </script>
    <base target="_blank" />
</head>
<body>
<div id="content">
<?php
    $webmoddir = "/mods/$moddir";
    $localmodfile = "/var/modules/$moddir/rachel-index.php";
    if (is_readable($localmodfile)) {
        $dir = $webmoddir;
        include $localmodfile;
    }
?>
</div>
</body>
</html>
