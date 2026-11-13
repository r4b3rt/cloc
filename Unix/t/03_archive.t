#!/usr/bin/env perl
#
# Tests for cloc's uncompress_archive_cmd(), the subroutine that returns
# the command list cloc passes to system() to expand an archive file.
#
#   Part 1:  unit tests.  The subroutine (plus external_utility_exists(),
#            which it calls) is lifted out of the cloc source and compiled
#            into a private package so every branch can be reached,
#            including the Windows-only ones.  External utilities are
#            simulated with stub programs in a private PATH directory.
#   Part 2:  end-to-end tests.  cloc is run against real archives whose
#            names and contents try to inject shell commands or write
#            outside of the extraction directory.
#
# Run from the Unix/ directory, as with the other tests:
#       t/03_archive.t          tests ../cloc
#       t/03_archive.t -u       tests ./cloc
#
use warnings;
use strict;
use Test::More;
use Cwd;
use File::Path qw( mkpath );
use File::Temp qw( tempdir );
use Getopt::Std;
my %opt;
getopts('u', \%opt);  # -u to run Unix/cloc instead of ../cloc

my $work_dir = getcwd;
my $cloc     = "$work_dir/../cloc";                 # all-purpose version
   $cloc     = "$work_dir/cloc" if defined $opt{u}; # Unix-tuned version
die "Cannot find $cloc; run this from the Unix/ directory\n" unless -r $cloc;

if ($^O =~ /^MSWin/) {
    plan skip_all => 'needs a Unix-like OS (stub utilities are sh scripts)';
}

my $tmp      = tempdir( CLEANUP => 1 );
my $real_PATH = $ENV{PATH};

# Stub utilities {{{1
# Each directory holds a different set of stand-in programs; pointing PATH
# at one of them controls which utilities cloc believes are installed.
my %Stub = (
    'cpio_gnu' => "#!/bin/sh\necho 'cpio (GNU cpio) 2.15'\n",
    'cpio_bsd' => "#!/bin/sh\necho 'bsdcpio 3.7.2 - libarchive 3.7.2'\n",
    'ok'       => "#!/bin/sh\nexit 0\n",
);
my %bin = (
    'all'         => { 'unzip'    => 'ok', 'rpm2cpio' => 'ok',
                       'dpkg-deb' => 'ok', 'cpio'     => 'cpio_gnu', },
    'bsd_cpio'    => { 'rpm2cpio' => 'ok', 'cpio'     => 'cpio_bsd', },
    'no_rpm2cpio' => { 'cpio'     => 'cpio_gnu', },
    'none'        => { },
);
foreach my $set (keys %bin) {
    my $dir = "$tmp/bin_$set";
    mkpath($dir);
    foreach my $exe (keys %{$bin{$set}}) {
        write_file("$dir/$exe", $Stub{ $bin{$set}{$exe} });
        chmod 0755, "$dir/$exe";
    }
    $bin{$set} = $dir;
}
# 1}}}
# Compile the subroutines under test {{{1
my $source = '';
{
    open my $fh, '<', $cloc or die "Cannot read $cloc: $!";
    local $/ = undef;
    my $all = <$fh>;
    close $fh;
    foreach my $sub (qw( uncompress_archive_cmd external_utility_exists )) {
        $all =~ /^(sub \Q$sub\E \{.*?^\}.*?)$/ms
            or die "Cannot find sub $sub in $cloc\n";
        $source .= "$1\n";
    }
}
{
    package Cloc;
    use File::Basename;
    use File::Spec;
    our ($opt_v, $opt_extract_with, $ON_WINDOWS) = (0, undef, 0);
    eval $source;
    die "Cannot compile subs taken from $cloc:\n$@" if $@;
}
# 1}}}

my $RPM_GNU = 'rpm2cpio "$1" | cpio -i --no-absolute-filenames';
my $RPM_BSD = 'rpm2cpio "$1" | cpio -i';
my $EVIL    = q{a b';touch PWNED;'"$(touch PWNED)`touch PWNED`|&<>*};

#
# Part 1:  unit tests
#
chdir $tmp;   # the Windows flavor of external_utility_exists() writes "nul"

# Unix-like, all utilities installed {{{1
my @Unix = (
    #  description               archive file           expected command
    [ '.tar'                  , '/d/a.tar'            , [ 'tar', 'xf', '/d/a.tar'     ] ],
    [ '.tar.gz'               , '/d/a.tar.gz'         , [ 'tar', 'xf', '/d/a.tar.gz'  ] ],
    [ '.tar.Z'                , '/d/a.tar.Z'          , [ 'tar', 'xf', '/d/a.tar.Z'   ] ],
    [ '.tar.xz'               , '/d/a.tar.xz'         , [ 'tar', 'xf', '/d/a.tar.xz'  ] ],
    [ '.tar.bz2'              , '/d/a.tar.bz2'        , [ 'tar', 'xf', '/d/a.tar.bz2' ] ],
    [ '.tgz'                  , '/d/a.tgz'            , [ 'tar', 'xf', '/d/a.tgz'     ] ],
    [ '.gem'                  , '/d/a.gem'            , [ 'tar', 'xf', '/d/a.gem'     ] ],
    [ '.zip'                  , '/d/a.zip'            , [ 'unzip', '-qq', '-d', '.', '/d/a.zip' ] ],
    [ '.ZIP'                  , '/d/a.ZIP'            , [ 'unzip', '-qq', '-d', '.', '/d/a.ZIP' ] ],
    [ '.whl'                  , '/d/a.whl'            , [ 'unzip', '-qq', '-d', '.', '/d/a.whl' ] ],
    [ '.deb'                  , '/d/a.deb'            , [ 'dpkg-deb', '-x', '/d/a.deb', '.' ] ],
    [ '.src.rpm'              , '/d/a.src.rpm'        , [ 'sh', '-c', $RPM_GNU, 'sh', '/d/a.src.rpm' ] ],
    [ 'STDIN'                 , '-'                   , [ 'sh', '-c', 'cat > -' ] ],
    [ 'STDIN with directory'  , '/d/-'                , [ 'sh', '-c', 'cat > -' ] ],
    [ 'source file'           , '/d/a.c'              , [ ] ],
    [ 'binary .rpm'           , '/d/a.rpm'            , [ ] ],
    [ 'tar in mid-name'       , '/d/a.tar.txt'        , [ ] ],
    # file names must never be mistaken for options or remote hosts
    [ 'leading dash .tar'     , '-I touch PWNED;.tar' , [ 'tar', 'xf', './-I touch PWNED;.tar' ] ],
    [ 'leading dash .zip'     , '-o.zip'              , [ 'unzip', '-qq', '-d', '.', './-o.zip' ] ],
    [ 'leading dash .deb'     , '--help.deb'          , [ 'dpkg-deb', '-x', './--help.deb', '.' ] ],
    [ 'leading dash .src.rpm' , '-v.src.rpm'          , [ 'sh', '-c', $RPM_GNU, 'sh', './-v.src.rpm' ] ],
    [ 'tar remote host syntax', 'host:a.tar'          , [ 'tar', 'xf', './host:a.tar' ] ],
    [ 'relative with dir'     , 'd/a.tar'             , [ 'tar', 'xf', './d/a.tar' ] ],
    # shell metacharacters stay inside a single list element
    [ 'hostile .tar'          , "/d/$EVIL.tar"        , [ 'tar', 'xf', "/d/$EVIL.tar" ] ],
    [ 'hostile .zip'          , "/d/$EVIL.zip"        , [ 'unzip', '-qq', '-d', '.', "/d/$EVIL.zip" ] ],
    [ 'hostile .deb'          , "/d/$EVIL.deb"        , [ 'dpkg-deb', '-x', "/d/$EVIL.deb", '.' ] ],
    [ 'hostile .src.rpm'      , "/d/$EVIL.src.rpm"    , [ 'sh', '-c', $RPM_GNU, 'sh', "/d/$EVIL.src.rpm" ] ],
    [ 'newline in name'       , "/d/a\nb.tar"         , [ 'tar', 'xf', "/d/a\nb.tar" ] ],
);
$ENV{PATH} = $bin{'all'};
foreach my $t (@Unix) {
    my ($name, $file, $expect) = @{$t};
    is_deeply([ cmd_for($file) ], $expect, "unix: $name");
}
# 1}}}
# Unix-like, cpio variants and missing utilities {{{1
$ENV{PATH} = $bin{'bsd_cpio'};
is_deeply([ cmd_for('/d/a.src.rpm') ],
          [ 'sh', '-c', $RPM_BSD, 'sh', '/d/a.src.rpm' ],
          'unix: .src.rpm with non-GNU cpio');

$ENV{PATH} = $bin{'no_rpm2cpio'};
like(died_with('/d/a.src.rpm'), qr/utility 'rpm2cpio' is not available/,
     'unix: .src.rpm without rpm2cpio dies');

$ENV{PATH} = $bin{'none'};
like(died_with('/d/a.src.rpm'), qr/utility 'cpio' is not available/,
     'unix: .src.rpm without cpio dies');
like(died_with('/d/a.zip'    ), qr/utility 'unzip' is not available/,
     'unix: .zip without unzip dies');
like(died_with('/d/a.whl'    ), qr/utility 'unzip' is not available/,
     'unix: .whl without unzip dies');
like(died_with('/d/a.deb'    ), qr/utility 'dpkg-deb' is not available/,
     'unix: .deb without dpkg-deb dies');
like(died_with('/d/a.zip'    ), qr/Unable to expand \/d\/a\.zip .*--extract-with/s,
     'unix: error names the file and suggests --extract-with');
is_deeply([ cmd_for('/d/a.tar') ], [ 'tar', 'xf', '/d/a.tar' ],
     'unix: .tar is not checked for utility existence');
# 1}}}
# Unix-like, --extract-with {{{1
$ENV{PATH} = $bin{'all'};
my @Extract_With = (
    [ 'pipeline'       , 'gzip -dc >FILE< | tar xf -'  , 'gzip -dc "$1" | tar xf -' ],
    [ 'simple'         , 'tar zxf >FILE<'              , 'tar zxf "$1"'             ],
    [ 'single quoted'  , "tar zxf '>FILE<'"            , 'tar zxf "$1"'             ],
    [ 'double quoted'  , 'tar zxf ">FILE<"'            , 'tar zxf "$1"'             ],
    [ 'used twice'     , 'ls >FILE< && tar xf >FILE<'  , 'ls "$1" && tar xf "$1"'   ],
    [ 'no placeholder' , 'tar xf fixed.tar'            , 'tar xf fixed.tar'         ],
);
foreach my $t (@Extract_With) {
    my ($name, $with, $script) = @{$t};
    foreach my $file ('/d/a.tar.gz', "/d/$EVIL.tar.gz", '/d/a.c', '-') {
        (my $show = $file) =~ s/\Q$EVIL\E/<hostile>/;
        is_deeply([ cmd_for($file, 'with' => $with) ],
                  [ 'sh', '-c', $script, 'sh', $file eq '-' ? './-' : $file ],
                  "unix: --extract-with $name, $show");
    }
}
# 1}}}
# Windows {{{1
my $WIN_EVIL = 'a b&calc.exe&^|<>';
my @Windows = (
    [ '.tar'             , 'C:\\d\\a.tar'          , [ 'tar', '-xf', 'C:\\d\\a.tar' ] ],
    [ '.tar with spaces' , 'C:\\my d\\a b.tar'     , [ 'tar', '-xf', 'C:\\my d\\a b.tar' ] ],
    [ '.tar.gz'          , 'C:\\d\\a.tar.gz'       , [ 'tar', 'xf', 'C:\\d\\a.tar.gz' ] ],
    [ '.zip'             , 'C:\\d\\a.zip'          , [ 'unzip', '-qq', '-d', '.', 'C:\\d\\a.zip' ] ],
    [ '.whl'             , 'C:\\d\\a.WHL'          , [ 'unzip', '-qq', '-d', '.', 'C:\\d\\a.WHL' ] ],
    [ '.zip with spaces' , 'C:\\my d\\a b.zip'     , [ 'unzip', '-qq', '-d', '.', 'C:\\my d\\a b.zip' ] ],
    [ 'hostile .tar'     , "C:\\d\\$WIN_EVIL.tar"  , [ 'tar', '-xf', "C:\\d\\$WIN_EVIL.tar" ] ],
    [ 'hostile .zip'     , "C:\\d\\$WIN_EVIL.zip"  , [ 'unzip', '-qq', '-d', '.', "C:\\d\\$WIN_EVIL.zip" ] ],
    [ 'leading dash .tar', '-a.tar'                , [ 'tar', '-xf', './-a.tar' ] ],
    [ 'leading dash .zip', '-a.zip'                , [ 'unzip', '-qq', '-d', '.', './-a.zip' ] ],
    [ '.tgz'             , 'C:\\d\\a.tgz'          , [ ] ],
    [ '.deb'             , 'C:\\d\\a.deb'          , [ ] ],
    [ '.src.rpm'         , 'C:\\d\\a.src.rpm'      , [ ] ],
    [ 'STDIN'            , '-'                     , [ ] ],
    [ 'source file'      , 'C:\\d\\a.c'            , [ ] ],
);
$ENV{PATH} = $bin{'all'};
foreach my $t (@Windows) {
    my ($name, $file, $expect) = @{$t};
    is_deeply([ cmd_for($file, 'windows' => 1) ], $expect, "windows: $name");
}
$ENV{PATH} = $bin{'none'};
{
    # cloc's Windows utility check leaves STDERR alone; keep the noise
    # from /bin/sh ("unzip: not found") out of the test output
    open my $save, '>&', \*STDERR or die $!;
    open STDERR, '>', '/dev/null' or die $!;
    my $error = died_with('C:\\d\\a.zip', 'windows' => 1);
    open STDERR, '>&', $save or die $!;
    like($error, qr/utility 'unzip' is not available/,
         'windows: .zip without unzip dies');
}
is_deeply([ cmd_for('C:\\d\\a.tar', 'windows' => 1) ],
          [ 'tar', '-xf', 'C:\\d\\a.tar' ],
          'windows: .tar is not checked for utility existence');

# --extract-with on Windows is run by cmd.exe, so comes back as one string
$ENV{PATH} = $bin{'all'};
my $winzip = '"c:\\Program Files\\WinZip\\WinZip32.exe" -e -o';
is_deeply([ cmd_for('C:\\my d\\a b.zip', 'windows' => 1,
                    'with' => "$winzip >FILE< .") ],
          [ "$winzip \"C:\\my d\\a b.zip\" ." ],
          'windows: --extract-with quotes the file name');
is_deeply([ cmd_for('C:\\my d\\a b.zip', 'windows' => 1,
                    'with' => "$winzip \">FILE<\" .") ],
          [ "$winzip \"C:\\my d\\a b.zip\" ." ],
          'windows: --extract-with does not double existing quotes');
is_deeply([ cmd_for("C:\\d\\$WIN_EVIL.zip", 'windows' => 1,
                    'with' => "$winzip >FILE< .") ],
          [ "$winzip \"C:\\d\\$WIN_EVIL.zip\" ." ],
          'windows: --extract-with keeps cmd.exe operators inside quotes');
like(died_with('C:\\d\\a"&calc.exe&".zip', 'windows' => 1,
               'with' => "$winzip >FILE< ."),
     qr/unsafe character/, 'windows: --extract-with rejects " in file name');
like(died_with('C:\\d\\%COMSPEC%.zip', 'windows' => 1,
               'with' => "$winzip >FILE< ."),
     qr/unsafe character/, 'windows: --extract-with rejects % in file name');
# 1}}}
# Verbose trace {{{1
$ENV{PATH} = $bin{'all'};
{
    my $trace = '';
    open my $save, '>&', \*STDOUT or die $!;
    close STDOUT;
    open STDOUT, '>', \$trace or die $!;
    my @cmd = cmd_for('/d/a.tar', 'v' => 3);
    close STDOUT;
    open STDOUT, '>&', $save or die $!;
    like($trace, qr{^-> uncompress_archive_cmd\(/d/a\.tar\)$}m,
         'verbose: entry trace');
    like($trace, qr{^<- uncompress_archive_cmd \(tar xf /d/a\.tar\)$}m,
         'verbose: exit trace shows the command');
}
# 1}}}
$ENV{PATH} = $real_PATH;
chdir $work_dir;

#
# Part 2:  end-to-end tests
#
my $C_CODE = "/* comment */\nint main() {\n\n    return 0;\n}\n";  # 3 code
my $e2e    = "$tmp/e2e";
my $src    = "$e2e/src";
mkpath("$src/pkg");
write_file("$src/pkg/hello.c", $C_CODE);
my $HOSTILE = q{a b';touch PWNED;'$(touch PWNED)`touch PWNED`};

sub have { return !system("which $_[0] >/dev/null 2>&1") }

# each archive type, with a file name that attacks the shell {{{1
my @Builders = (
    # extension, required utilities, command list to create archive >OUT<
    [ 'tar'    , [ 'tar'         ], [ 'tar', 'cf' , '>OUT<', '-C', $src, 'pkg' ] ],
    [ 'tar.gz' , [ 'tar', 'gzip' ], [ 'tar', 'czf', '>OUT<', '-C', $src, 'pkg' ] ],
    [ 'tgz'    , [ 'tar', 'gzip' ], [ 'tar', 'czf', '>OUT<', '-C', $src, 'pkg' ] ],
    [ 'tar.bz2', [ 'tar', 'bzip2'], [ 'tar', 'cjf', '>OUT<', '-C', $src, 'pkg' ] ],
    [ 'tar.xz' , [ 'tar', 'xz'   ], [ 'tar', 'cJf', '>OUT<', '-C', $src, 'pkg' ] ],
    [ 'zip'    , [ 'zip', 'unzip'], [ 'sh', '-c', 'cd "$1" && zip -qr "$2" pkg', 'sh', $src, '>OUT<' ] ],
    [ 'whl'    , [ 'zip', 'unzip'], [ 'sh', '-c', 'cd "$1" && zip -qr "$2" pkg', 'sh', $src, '>OUT<' ] ],
);
foreach my $b (@Builders) {
    my ($ext, $need, $build) = @{$b};
    SKIP: {
        my @absent = grep { !have($_) } @{$need};
        skip "e2e .$ext: no @absent", 4 if @absent;
        foreach my $base ('plain', $HOSTILE, 'host:colon') {
            my $dir = new_dir();
            my $archive = "$dir/$base.$ext";
            system(map { $_ eq '>OUT<' ? $archive : $_ } @{$build});
            (my $show = $base) =~ s/\Q$HOSTILE\E/hostile/;
            is(c_code_lines($dir, "$base.$ext"), 3, "e2e .$ext, $show name: counted");
            ok(!pwned($dir), "e2e .$ext, $show name: nothing injected")
                if $base eq $HOSTILE;
        }
    }
}
# 1}}}
# .deb {{{1
SKIP: {
    skip 'e2e .deb: no dpkg-deb', 2 unless have('dpkg-deb');
    my $dir = new_dir();
    mkpath("$dir/root/DEBIAN");
    mkpath("$dir/root/usr/src");
    write_file("$dir/root/usr/src/hello.c", $C_CODE);
    write_file("$dir/root/DEBIAN/control",
               "Package: cloctest\nVersion: 1.0\nArchitecture: all\n" .
               "Maintainer: nobody <nobody\@example.com>\n"           .
               "Description: cloc test package\n");
    my $archive = "$dir/$HOSTILE.deb";
    system("dpkg-deb --build '$dir/root' '$dir/plain.deb' >/dev/null 2>&1");
    rename "$dir/plain.deb", $archive;
    system('rm', '-rf', "$dir/root");
    is(c_code_lines($dir, "$HOSTILE.deb"), 3, 'e2e .deb, hostile name: counted');
    ok(!pwned($dir), 'e2e .deb, hostile name: nothing injected');
}
# 1}}}
# .src.rpm {{{1
# A stand-in rpm2cpio (it only cats its argument) lets a plain cpio archive
# play the role of a source RPM, so rpmbuild isn't needed.
SKIP: {
    skip 'e2e .src.rpm: no cpio', 5 unless have('cpio');
    my $fake = "$e2e/fakebin";
    mkpath($fake);
    write_file("$fake/rpm2cpio", "#!/bin/sh\ncat \"\$1\"\n");
    chmod 0755, "$fake/rpm2cpio";
    local $ENV{PATH} = "$fake:$real_PATH";

    my $dir = new_dir();
    system('sh', '-c', 'cd "$1" && echo hello.c | cpio -o --quiet > "$2" 2>/dev/null',
           'sh', "$src/pkg", "$dir/$HOSTILE.src.rpm");
    is(c_code_lines($dir, "$HOSTILE.src.rpm"), 3,
       'e2e .src.rpm, hostile name: counted');
    ok(!pwned($dir), 'e2e .src.rpm, hostile name: nothing injected');

    # members with absolute or ../ paths must not escape the extract dir
    my $gnu = `cpio --version 2>&1` =~ /GNU/;
    skip 'e2e .src.rpm path escape: cpio is not GNU cpio', 3 unless $gnu;
    $dir = new_dir();
    my $victim = "$dir/victim";
    mkpath("$victim/deep");
    write_file("$victim/absolute.c", $C_CODE);
    write_file("$victim/dotdot.c"  , $C_CODE);
    system('sh', '-c',
           'cd "$1/deep" && printf "%s\n" "$1/absolute.c" ../dotdot.c | ' .
           'cpio -o --quiet > "$2" 2>/dev/null',
           'sh', $victim, "$dir/escape.src.rpm");
    unlink "$victim/absolute.c", "$victim/dotdot.c";
    my $sdir = "$dir/sdir/a/b";   # so ../ from the extract dir is observable
    mkpath($sdir);
    run_cloc($dir, "--sdir '$sdir' escape.src.rpm");
    ok(!-e "$victim/absolute.c", 'e2e .src.rpm: absolute member path not written');
    my @strays = grep { !m{^\Q$sdir\E/} } split(/\n/, `find '$dir' -name dotdot.c`);
    is_deeply(\@strays, [], 'e2e .src.rpm: ../ member path stays in extract dir');
    ok(scalar(() = `find '$sdir' -name '*.c'`) >= 1,
       'e2e .src.rpm: members were extracted inside the extract dir');
}
# 1}}}
# STDIN {{{1
{
    my $dir = new_dir();
    my $out = run_cloc($dir, "--stdin-name=x.c - < '$src/pkg/hello.c'");
    is(c_code($out), 3, 'e2e STDIN: counted');
}
# 1}}}
# archive within an archive {{{1
SKIP: {
    my @absent = grep { !have($_) } qw( tar zip unzip );
    skip "e2e nested archive: no @absent", 2 if @absent;
    my $dir = new_dir();
    mkpath("$dir/outer");
    system('tar', 'cf', "$dir/outer/$HOSTILE.tar", '-C', $src, 'pkg');
    system('sh', '-c', 'cd "$1" && zip -qr ../outer.zip .', 'sh', "$dir/outer");
    system('rm', '-rf', "$dir/outer");
    is(c_code_lines($dir, 'outer.zip'), 3, 'e2e nested hostile .tar in .zip: counted');
    ok(!pwned($dir), 'e2e nested hostile .tar in .zip: nothing injected');
}
# 1}}}
# --extract-with {{{1
SKIP: {
    my @absent = grep { !have($_) } qw( tar gzip );
    skip "e2e --extract-with: no @absent", 6 if @absent;
    foreach my $with ('gzip -dc >FILE< | tar xf -',      # from cloc --help
                      "gzip -dc '>FILE<' | tar xf -",
                      'tar zxf >FILE<') {
        my $dir = new_dir();
        system('tar', 'czf', "$dir/$HOSTILE.tar.gz", '-C', $src, 'pkg');
        my $out = run_cloc($dir, "--extract-with=\"$with\" " .
                                 shell_quote("$HOSTILE.tar.gz"));
        is(c_code($out), 3, "e2e --extract-with=\"$with\": counted");
        ok(!pwned($dir), "e2e --extract-with=\"$with\": nothing injected");
    }
}
# 1}}}
chdir $work_dir;
done_testing();
print "Finished testing $cloc\n";

sub cmd_for {                                # {{{1
    # Returns what uncompress_archive_cmd() returns for the given archive
    # file.  Options:  windows => 1, with => "--extract-with value", v => N
    my ($file, %o) = @_;
    local $Cloc::ON_WINDOWS       = $o{'windows'} ? 1 : 0;
    local $Cloc::opt_extract_with = $o{'with'};
    local $Cloc::opt_v            = $o{'v'} || 0;
    return Cloc::uncompress_archive_cmd($file);
} # 1}}}
sub died_with {                              # {{{1
    # Returns the text uncompress_archive_cmd() died with, or '' if it lived.
    my @args = @_;
    my $lived = eval { cmd_for(@args); 1 };
    return $lived ? '' : $@;
} # 1}}}
sub write_file {                             # {{{1
    my ($file, $text) = @_;
    open my $fh, '>', $file or die "Cannot write $file: $!";
    print $fh $text;
    close $fh;
} # 1}}}
{
my $n_dir = 0;
sub new_dir {                                # {{{1
    # A fresh, empty directory for one end-to-end case.
    my $dir = sprintf "%s/case_%02d", $e2e, ++$n_dir;
    mkpath($dir);
    return $dir;
} # 1}}}
}
sub shell_quote {                            # {{{1
    my ($text) = @_;
    $text =~ s/'/'\\''/g;
    return "'$text'";
} # 1}}}
sub run_cloc {                               # {{{1
    # Runs cloc from within $dir; returns its CSV output.
    my ($dir, $args) = @_;
    chdir $dir or die "Cannot cd $dir: $!";
    my $out = `$^X '$cloc' --quiet --csv $args 2>/dev/null`;
    chdir $work_dir;
    return defined $out ? $out : '';
} # 1}}}
sub c_code {                                 # {{{1
    # Lines of C code reported in cloc's CSV output, -1 if no C was counted.
    my ($csv) = @_;
    return $csv =~ /^\d+,C,\d+,\d+,(\d+)$/m ? $1 : -1;
} # 1}}}
sub c_code_lines {                           # {{{1
    my ($dir, $file) = @_;
    return c_code(run_cloc($dir, shell_quote($file)));
} # 1}}}
sub pwned {                                  # {{{1
    # True if an injected "touch PWNED" ran anywhere beneath $dir, or in
    # the directory cloc was started from.
    my ($dir) = @_;
    my $found = `find '$dir' -name PWNED 2>/dev/null`;
    return length($found) ? 1 : 0;
} # 1}}}
