# <@LICENSE>
# Licensed under the Apache License 2.0. You may not use this file except in
# compliance with the License.  You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

# Author:  Kent Oyer <kent@mxguardian.net>

=encoding utf8

=head1 NAME

Mail::SpamAssassin::Plugin::ASCII - SpamAssassin plugin to convert non-ASCII characters to their ASCII equivalents

=head1 SYNOPSIS

  loadplugin Mail::SpamAssassin::Plugin::ASCII

  ascii      RULE_NAME   /You have a new voice-?mail/i
  describe   RULE_NAME   Voice mail spam
  score      RULE_NAME   1.0

=head1 DESCRIPTION

This plugin attempts to convert non-ASCII characters to their ASCII equivalents
and then run rules against the converted text.  This is useful for
catching spam that uses non-ASCII characters to obfuscate words. For example,

    Ýou hãve a nèw vòice-mãil
    PαyPal
    You havé Reꞓeìved an Enꞓryptéd Company Maíl
    ѡѡѡ.ЬіɡЬаɡ.ϲо.zа

would be converted to

    You have a new voice-mail
    PayPal
    You have ReCeived an EnCrypted Company Mail
    www.bigbag.co.za

Unlike other transliteration software, this plugin converts non-ASCII characters
to their ASCII equivalents based on appearance instead of meaning. For example, the
German eszett character 'ß' is converted to the Roman letter 'B' instead of 'ss'
because it resembles a 'B' in appearance. Likewise, the Greek letter Sigma ('Σ') is
converted to 'E' and a lower case Omega ('ω') is converted to 'w' even though these
letters have different meanings than their originals.

Not all non-ASCII characters are converted. For example, the Japanese Hiragana
character 'あ' is not converted because it does not resemble any ASCII character.
Characters that have no ASCII equivalent are removed from the text.

The plugin also removes zero-width characters such as the zero-width
space (U+200B) and zero-width non-joiner (U+200C) that are often used to
obfuscate words.

If you want to write rules that match against the original non-ASCII text,
you can still do so by using the standard C<body> and C<rawbody> rules. The
converted text is only used when evaluating rules that use the C<ascii> rule type.

Note that obfuscation is still possible within the ASCII character set. For example,
the letter 'O' can be replaced with the number '0' and the letter 'l' can be replaced
with the number '1' as in "PayPa1 0rder". This plugin does not attempt to catch these
types of obfuscation. Therefore, you still need to use other techniques such as using
a character class or C<replace_tags> to catch these types of obfuscation.

=cut

package Mail::SpamAssassin::Plugin::ASCII;
use strict;
use warnings FATAL => 'all';
use v5.12;
use Encode;
use Data::Dumper;
use utf8;

our $VERSION = 0.03;

use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Logger qw(would_log);
use Mail::SpamAssassin::Util qw(compile_regexp &is_valid_utf_8 &untaint_var);

our @ISA = qw(Mail::SpamAssassin::Plugin);

my $would_log_rules_all;

# constructor
sub new {
    my $class = shift;
    my $mailsaobject = shift;

    # some boilerplate...
    $class = ref($class) || $class;
    my $self = $class->SUPER::new($mailsaobject);
    bless ($self, $class);

    $self->set_config($mailsaobject->{conf});
    $self->load_map();

    $would_log_rules_all = would_log('dbg', 'rules-all') == 2;

    return $self;
}

sub dbg { Mail::SpamAssassin::Logger::dbg ("ScriptInfo: @_"); }
sub info { Mail::SpamAssassin::Logger::info ("ScriptInfo: @_"); }

sub load_map {
    my ($self) = @_;

    # build character map from __DATA__ section
    my %char_map;
    while (<DATA>) {
        chomp;
        my ($key,$value) = split /\s+/;
        my $ascii = join('', map { chr(hex($_)) } split /\+/, $value);
        $char_map{chr(hex($key))} = $ascii;
    }
    $self->{char_map} = \%char_map;
    close DATA;

}

sub set_config {
    my ($self, $conf) = @_;
    my @cmds;

    push (@cmds, (
        {
            setting => 'ascii',
            is_priv => 1,
            type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
            code => sub {
                my ($self, $key, $value, $line) = @_;

                if ($value !~ /^(\S+)\s+(.+)$/) {
                    return $Mail::SpamAssassin::Conf::INVALID_VALUE;
                }
                my $name = $1;
                my $pattern = $2;

                my ($re, $err) = compile_regexp($pattern, 1);
                if (!$re) {
                    dbg("Error parsing rule: invalid regexp '$pattern': $err");
                    return $Mail::SpamAssassin::Conf::INVALID_VALUE;
                }

                $conf->{parser}->{conf}->{ascii_rules}->{$name} = $re;

                # just define the test so that scores and lint works
                $self->{parser}->add_test($name, undef,
                    $Mail::SpamAssassin::Conf::TYPE_EMPTY_TESTS);


            }
        }
    ));

    $conf->{parser}->register_commands(\@cmds);
}

sub finish_parsing_end    {
    my ($self, $opts) = @_;

    my $conf = $opts->{conf};
    return unless exists $conf->{ascii_rules};

    # build eval string to compile rules
    my $eval = <<'EOF';
package Mail::SpamAssassin::Plugin::ASCII;

sub _run_ascii_rules {
    my ($self, $opts) = @_;
    my $pms = $opts->{permsgstatus};
    my $test_qr;

    # check all script rules
    my $ascii_body = $self->_get_ascii_body($pms);

EOF

    foreach my $name (keys %{$conf->{ascii_rules}}) {
        my $test_qr = $conf->{ascii_rules}->{$name};
        my $tflags = $conf->{tflags}->{$name} || '';
        my $score = $conf->{scores}->{$name} || 1;

        if ( $would_log_rules_all ) {
            $eval .= qq(    dbg("running rule $name $test_qr");\n);
        }

        $eval .= <<"EOF";
    \$test_qr = \$pms->{conf}->{ascii_rules}->{$name};
    foreach my \$line (\@\$ascii_body) {
        if ( \$line =~ /\$test_qr/p ) {
EOF
        if ( $would_log_rules_all ) {
            $eval .= <<EOF;
            dbg(qq(ran rule $name ======> got hit ").(defined \${^MATCH} ? \${^MATCH} : '<negative match>').qq("));
EOF
        }
        $eval .= <<"EOF";
            \$pms->{pattern_hits}->{$name} = \${^MATCH} if defined \${^MATCH};
            \$pms->got_hit('$name','ASCII: ','ruletype' => 'body', 'score' => $score);
            last;
        }
    }
EOF
    }
    $eval .= <<'EOF';
}

sub parsed_metadata {
    my ($self, $opts) = @_;

    $self->_run_ascii_rules($opts);

}

EOF

    eval untaint_var($eval);
    if ($@) {
        die("Error compiling ascii rules: $@");
    }

}
#
# Get the body of the message as an array of lines
#
sub _get_ascii_body {
    my ($self, $pms) = @_;

    # locate the main body part (prefer html over text)
    my $body_part;
    foreach my $p ($pms->{msg}->find_parts(qr(text/))) {
        my ($ctype, $boundary, $charset, $name) = Mail::SpamAssassin::Util::parse_content_type($p->get_header('content-type'));

        # skip parts with a filename
        next if defined $name;

        # take the first text/html part we find
        if ( lc($ctype) eq 'text/html' ) {
            $body_part = $p;
            last;
        }

        # otherwise take the first text/plain part we find
        $body_part = $p unless defined $body_part;
    }

    # if we didn't find a text part, return empty list
    return [] unless defined $body_part;

    # get subject
    my $subject = $pms->{msg}->get_header('subject') || '';
    $subject = decode('UTF-8', $subject);

    my $body = $body_part->rendered();
    if ( is_valid_utf_8($body)) {
        $body = decode('UTF-8', $body);
    }
    $body = $subject . "\n" . $body;

    # remove zero-width characters and combining marks
    $body =~ s/[\xAD\x{034F}\x{200B}-\x{200F}\x{202A}\x{202B}\x{202C}\x{2060}\x{FEFF}]|\p{Combining_Mark}//g;

    # replace non-ascii characters with ascii equivalents
    my $map = $self->{char_map};
    $body =~ s/([^[:ascii:]])/defined($map->{$1})?$map->{$1}:' '/eg;

    # reduce spaces
    $body =~ s/\x{20}+/ /g;

    # print STDERR "SUBJECT: $subject\n";
    # print STDERR "BODY: $body\n";
    my @lines = split(/\n/, $body);
    return \@lines;
}

1;

__DATA__
00A0 20
00A9 28+43+29
00AA 61
00AE 28+52+29
00B2 32
00B3 33
00B5 75
00B7 2E
00B8 2C
00B9 31
00BA 6F
00C0 41
00C1 41
00C2 41
00C3 41
00C4 41
00C5 41
00C6 41+45
00C7 43
00C8 45
00C9 45
00CA 45
00CB 45
00CC 49
00CD 49
00CE 49
00CF 49
00D0 44
00D1 4E
00D2 4F
00D3 4F
00D4 4F
00D5 4F
00D6 4F
00D7 78
00D8 4F
00D9 55
00DA 55
00DB 55
00DC 55
00DD 59
00DF 42
00E0 61
00E1 61
00E2 61
00E3 61
00E4 61
00E5 61
00E6 61+65
00E7 63
00E8 65
00E9 65
00EA 65
00EB 65
00EC 69
00ED 69
00EE 69
00EF 69
00F0 6F
00F1 6E
00F2 6F
00F3 6F
00F4 6F
00F5 6F
00F6 6F
00F8 6F
00F9 75
00FA 75
00FB 75
00FC 75
00FD 79
00FF 79
0100 41
0101 61
0102 41
0103 61
0104 41
0105 61
0106 43
0107 63
0108 43
0109 63
010A 43
010B 63
010C 43
010D 63
010E 44
010F 64
0110 44
0111 64
0112 45
0113 65
0114 45
0115 65
0116 45
0117 65
0118 45
0119 65
011A 45
011B 65
011C 47
011D 67
011E 47
011F 67
0120 47
0121 67
0122 47
0123 67
0124 48
0125 68
0126 48
0127 68
0128 49
0129 69
012A 49
012B 69
012C 49
012D 69
012E 49
012F 69
0130 49
0131 69
0132 49+4A
0133 69+6A
0134 4A
0135 6A
0136 4B
0137 6B
0138 6B
0139 4C
013A 6C
013B 4C
013C 6C
013D 4C
013E 6C
013F 4C
0140 6C
0141 4C
0142 6C
0143 4E
0144 6E
0145 4E
0146 6E
0147 4E
0148 6E
0149 6E
014A 4E
014B 6E
014C 4F
014D 6F
014E 4F
014F 6F
0150 4F
0151 6F
0152 4F+45
0153 6F+65
0154 52
0155 72
0156 52
0157 72
0158 52
0159 72
015A 53
015B 73
015C 53
015D 73
015E 53
015F 73
0160 53
0161 73
0162 54
0163 74
0164 54
0165 74
0166 54
0167 74
0168 55
0169 75
016A 55
016B 75
016C 55
016D 75
016E 55
016F 75
0170 55
0171 75
0172 55
0173 75
0174 57
0175 77
0176 59
0177 79
0178 59
0179 5A
017A 7A
017B 5A
017C 7A
017D 5A
017E 7A
017F 66
0180 62
0181 42
0182 62
0183 62
0184 62
0185 62
0187 43
0188 63
0189 44
018A 44
018B 61
018C 61
018D 67
0190 45
0191 46
0192 66
0193 47
0194 56
0196 6C
0197 49
0198 4B
0199 6B
019A 6C
019C 57
019D 4E
019E 6E
019F 4F
01A0 4F
01A1 6F
01A4 50
01A5 70
01A6 52
01A7 32
01A8 32
01A9 45
01AB 74
01AC 54
01AD 74
01AE 54
01AF 55
01B0 75
01B1 55
01B2 56
01B3 59
01B4 79
01B5 5A
01B6 7A
01B7 33
01B8 45
01B9 45
01BB 32
01BC 35
01BD 73
01BF 70
01C0 6C
01C3 21
01C4 44+5A
01C5 44+7A
01C6 64+7A
01C7 4C+4A
01C8 4C+6A
01C9 6C+6A
01CA 4E+4A
01CB 4E+6A
01CC 6E+6A
01CD 41
01CE 61
01CF 49
01D0 69
01D1 4F
01D2 6F
01D3 55
01D4 75
01D5 55
01D6 75
01D7 55
01D8 75
01D9 55
01DA 75
01DB 55
01DC 75
01DE 41
01DF 61
01E0 41
01E1 61
01E2 41+45
01E3 61+65
01E4 47
01E5 67
01E6 47
01E7 67
01E8 4B
01E9 6B
01EA 4F
01EB 6F
01EC 4F
01ED 6F
01EE 33
01EF 33
01F0 6A
01F1 44+5A
01F2 44+7A
01F3 64+7A
01F4 47
01F5 67
01F6 48
01F7 50
01F8 4E
01F9 6E
01FA 41
01FB 61
01FC 41+45
01FD 61+65
01FE 4F
01FF 6F
0200 41
0201 61
0202 41
0203 61
0204 45
0205 65
0206 45
0207 65
0208 49
0209 69
020A 49
020B 69
020C 4F
020D 6F
020E 4F
020F 6F
0210 52
0211 72
0212 52
0213 72
0214 55
0215 75
0216 55
0217 75
0218 53
0219 73
021A 54
021B 74
021C 33
021D 33
021E 48
021F 68
0220 6E
0221 64
0222 38
0223 38
0224 5A
0225 7A
0226 41
0227 61
0228 45
0229 65
022A 4F
022B 6F
022C 4F
022D 6F
022E 4F
022F 6F
0230 4F
0231 6F
0232 59
0233 79
0234 6C
0235 6E
0236 74
0237 6A
0238 64+62
0239 71+70
023A 41
023B 43
023C 63
023D 4C
023E 54
023F 73
0240 7A
0241 3F
0242 32
0243 42
0244 55
0246 45
0247 65
0248 4A
0249 6A
024A 51
024B 71
024C 52
024D 72
024E 59
024F 79
0251 61
0253 62
0255 63
0256 64
0257 64
025B 65
025C 33
025D 33
025E 67
025F 6A
0260 67
0261 67
0262 47
0263 79
0265 75
0266 68
0267 68
0268 69
0269 69
026A 69
026B 6C
026C 6C
026D 6C
026F 77
0270 77
0271 6D
0272 6E
0273 6E
0274 4E
0275 6F
0276 4F+45
027C 72
027D 72
027E 72
0280 52
0282 73
0284 66
0288 74
0289 75
028B 75
028D 6D
028F 79
0290 7A
0291 7A
0292 33
0293 33
0294 3F
0297 43
0298 4F
0299 42
029B 47
029C 48
029D 6A
029F 4C
02A0 71
02A1 3F
02B0 68
02B2 6A
02B3 72
02B7 77
02B8 79
02BA 22
02C2 3C
02C3 3E
02C4 5E
02C6 5E
02D0 3A
02D7 2D
02DB 69
02DC 7E
02DD 22
02E1 6C
02E2 73
02E3 78
02EE 22
02F6 22
02F8 3A
0372 74
0373 74
0376 4E
0377 6E
037A 69
037C 63
037E 3B
037F 4A
0386 41
0387 2E
0388 45
0389 48
038A 49
038C 4F
038E 59
0390 69
0391 41
0392 42
0395 45
0396 5A
0397 48
0399 49
039A 4B
039C 4D
039D 4E
039F 4F
03A1 50
03A3 45
03A4 54
03A5 59
03A6 4F
03A7 58
03A8 57
03AA 49
03AB 59
03AC 61
03AD 65
03AE 6E
03AF 69
03B0 75
03B1 61
03B2 42
03B3 79
03B4 64
03B5 65
03B6 7A
03B7 6E
03B8 6F
03B9 69
03BA 6B
03BC 75
03BD 76
03BE 65
03BF 6F
03C0 6E
03C1 70
03C2 63
03C3 6F
03C4 74
03C5 75
03C7 78
03C8 77
03C9 77
03CA 69
03CB 75
03CC 6F
03CD 75
03CE 77
03CF 4B
03D0 42
03D2 59
03D3 59
03D4 59
03D6 77
03D7 6B
03D8 4F
03D9 6F
03DA 43
03DB 63
03DC 46
03DD 66
03DE 73
03E2 77
03E3 77
03E4 34
03E5 34
03E6 62
03E7 73
03E8 32
03E9 32
03EC 36
03ED 36
03EE 74
03EF 74
03F0 6B
03F1 70
03F2 63
03F3 6A
03F4 4F
03F5 65
03F9 43
03FA 4D
03FB 6D
03FC 70
03FE 43
0400 45
0405 53
0406 49
0408 4A
040D 4E
0410 41
0412 42
0415 45
0417 33
041A 4B
041C 4D
041D 48
041E 4F
0420 50
0421 43
0422 54
0425 58
042C 62
0430 61
0431 36
0433 72
0435 65
043A 6B
043E 6F
043F 6E
0440 70
0441 63
0442 74
0443 79
0445 78
0446 75
0455 73
0456 69
0458 6A
045D 6E
0461 77
0474 56
0475 76
049C 4B
049D 4B
04A4 48
04A5 48
04AE 59
04AF 79
04B3 78
04B8 34
04B9 34
04BB 68
04C0 6C
04CF 69
04D0 41
04D1 61
04D2 41
04D3 61
04D4 41+45
04D5 61+65
04E0 33
04E2 4E
04E3 6E
04E4 4E
04E5 6E
04E6 4F
04E7 6F
04EC 33
04ED 33
04EE 59
04EF 79
04F0 59
04F1 79
04F2 59
04F3 79
0501 64
050C 47
051B 71
051C 57
051D 77
0545 33
054D 55
054F 53
0555 4F
0561 77
0563 71
0566 71
0570 68
0575 6A
0578 6E
057C 6E
057D 75
0581 67
0584 70
0585 6F
0587 75
0589 3A
05C3 3A
05D5 69
05D8 76
05DF 6C
05E1 6F
05F0 6C+6C
05F2 22
05F4 22
0609 25
060A 25
0660 2E
0665 6F
066A 25
066B 2C
066D 2A
06AC 4A
06AE 4A
06B6 4A
06B7 4A
06B8 4A
06B9 55
06BD 55
06D4 2E
06F0 2E
0701 2E
0702 2E
0703 3A
0704 3A
075D 45
075E 45
075F 45
076B 6A
07C0 6F
07CA 6C
07FA 5F
0903 3A
0966 6F
097D 3F
09E6 6F
09EA 38
09ED 39
0A66 6F
0A67 39
0A6A 38
0A83 3A
0AE6 6F
0B03 38
0B20 4F
0B66 6F
0B68 39
0BD0 43
0BE6 6F
0C02 6F
0C66 6F
0C82 6F
0CE6 6F
0D02 6F
0D20 6F
0D66 6F
0D82 6F
0E50 6F
0ED0 6F
101D 6F
1040 6F
10E7 79
13A0 44
13A1 52
13A2 54
13A5 69
13A9 59
13AA 41
13AB 4A
13AC 45
13B3 57
13B7 4D
13BB 48
13BD 59
13C0 47
13C2 68
13C3 5A
13CE 34
13CF 62
13D2 52
13D4 57
13D5 53
13D9 56
13DA 53
13DE 4C
13DF 43
13E2 50
13E6 4B
13E7 4A
13F3 47
13F4 42
142F 56
144C 55
146D 50
146F 64
148D 4A
14AA 4C
14BF 32
1541 78
157C 48
157D 78
1587 52
15AF 62
15B4 46
15C5 41
15DE 44
15EA 44
15F0 4D
15F7 42
166D 58
166E 78
1680 20
1735 2F
1803 3A
1809 3A
180E 20
1D04 63
1D0B 6B
1D0F 6F
1D11 6F
1D1B 74
1D1C 75
1D20 76
1D21 77
1D22 7A
1D26 72
1D28 6E
1D2C 41
1D2E 42
1D30 44
1D31 45
1D33 47
1D34 48
1D35 49
1D36 4A
1D37 4B
1D38 4C
1D39 4D
1D3A 4E
1D3C 4F
1D3E 50
1D3F 52
1D40 54
1D41 55
1D42 57
1D43 61
1D47 62
1D48 64
1D49 65
1D4D 67
1D4F 6B
1D50 6D
1D52 6F
1D56 70
1D57 74
1D58 75
1D5B 76
1D62 69
1D63 72
1D64 75
1D65 76
1D6C 62
1D6D 64
1D6E 66
1D6F 6D
1D70 6E
1D71 70
1D72 66
1D73 66
1D74 73
1D75 74
1D76 7A
1D7B 49
1D7D 70
1D7E 75
1D80 62
1D81 64
1D82 66
1D83 67
1D85 6C
1D86 6D
1D87 6E
1D88 70
1D89 72
1D8A 73
1D8C 79
1D8D 78
1D8E 7A
1D8F 61
1D91 64
1D92 65
1D96 69
1D99 75
1D9C 63
1DA0 66
1DBB 7A
1E00 41
1E01 61
1E02 42
1E03 62
1E04 42
1E05 62
1E06 42
1E07 62
1E08 43
1E09 63
1E0A 44
1E0B 64
1E0C 44
1E0D 64
1E0E 44
1E0F 64
1E10 44
1E11 64
1E12 44
1E13 64
1E14 45
1E15 65
1E16 45
1E17 65
1E18 45
1E19 65
1E1A 45
1E1B 65
1E1C 45
1E1D 65
1E1E 46
1E1F 66
1E20 47
1E21 67
1E22 48
1E23 68
1E24 48
1E25 68
1E26 48
1E27 68
1E28 48
1E29 68
1E2A 48
1E2B 68
1E2C 49
1E2D 69
1E2E 49
1E2F 69
1E30 4B
1E31 6B
1E32 4B
1E33 6B
1E34 4B
1E35 6B
1E36 4C
1E37 6C
1E38 4C
1E39 6C
1E3A 4C
1E3B 6C
1E3C 4C
1E3D 6C
1E3E 4D
1E3F 6D
1E40 4D
1E41 6D
1E42 4D
1E43 6D
1E44 4E
1E45 6E
1E46 4E
1E47 6E
1E48 4E
1E49 6E
1E4A 4E
1E4B 6E
1E4C 4F
1E4D 6F
1E4E 4F
1E4F 6F
1E50 4F
1E51 6F
1E52 4F
1E53 6F
1E54 50
1E55 70
1E56 50
1E57 70
1E58 52
1E59 72
1E5A 52
1E5B 72
1E5C 52
1E5D 72
1E5E 52
1E5F 72
1E60 53
1E61 73
1E62 53
1E63 73
1E64 53
1E65 73
1E66 53
1E67 73
1E68 53
1E69 73
1E6A 54
1E6B 74
1E6C 54
1E6D 74
1E6E 54
1E6F 74
1E70 54
1E71 74
1E72 55
1E73 75
1E74 55
1E75 75
1E76 55
1E77 75
1E78 55
1E79 75
1E7A 55
1E7B 75
1E7C 56
1E7D 76
1E7E 56
1E7F 76
1E80 57
1E81 77
1E82 57
1E83 77
1E84 57
1E85 77
1E86 57
1E87 77
1E88 57
1E89 77
1E8A 58
1E8B 78
1E8C 58
1E8D 78
1E8E 59
1E8F 79
1E90 5A
1E91 7A
1E92 5A
1E93 7A
1E94 5A
1E95 7A
1E96 68
1E97 74
1E98 77
1E99 79
1E9A 61
1E9B 73
1E9D 66
1EA0 41
1EA1 61
1EA2 41
1EA3 61
1EA4 41
1EA5 61
1EA6 41
1EA7 61
1EA8 41
1EA9 61
1EAA 41
1EAB 61
1EAC 41
1EAD 61
1EAE 41
1EAF 61
1EB0 41
1EB1 61
1EB2 41
1EB3 61
1EB4 41
1EB5 61
1EB6 41
1EB7 61
1EB8 45
1EB9 65
1EBA 45
1EBB 65
1EBC 45
1EBD 65
1EBE 45
1EBF 65
1EC0 45
1EC1 65
1EC2 45
1EC3 65
1EC4 45
1EC5 65
1EC6 45
1EC7 65
1EC8 49
1EC9 69
1ECA 49
1ECB 69
1ECC 4F
1ECD 6F
1ECE 4F
1ECF 6F
1ED0 4F
1ED1 6F
1ED2 4F
1ED3 6F
1ED4 4F
1ED5 6F
1ED6 4F
1ED7 6F
1ED8 4F
1ED9 6F
1EDA 4F
1EDB 6F
1EDC 4F
1EDD 6F
1EDE 4F
1EDF 6F
1EE0 4F
1EE1 6F
1EE2 4F
1EE3 6F
1EE4 55
1EE5 75
1EE6 55
1EE7 75
1EE8 55
1EE9 75
1EEA 55
1EEB 75
1EEC 55
1EED 75
1EEE 55
1EEF 75
1EF0 55
1EF1 75
1EF2 59
1EF3 79
1EF4 59
1EF5 79
1EF6 59
1EF7 79
1EF8 59
1EF9 79
1EFE 59
1EFF 79
1F60 77
1F61 77
1F62 77
1F63 77
1F64 77
1F65 77
1F66 77
1F67 77
1F7C 77
1F7D 77
1FA0 77
1FA1 77
1FA2 77
1FA3 77
1FA4 77
1FA5 77
1FA6 77
1FA7 77
1FBE 69
1FC0 7E
1FF2 77
1FF3 77
1FF4 77
1FF6 77
1FF7 77
2000 20
2001 20
2002 20
2003 20
2004 20
2005 20
2006 20
2007 20
2008 20
2009 20
200A 20
2010 2D
2011 2D
2012 2D
2013 2D
201A 2C
201C 22
201D 22
201F 22
2024 2E
2025 2E+2E
2026 2E+2E+2E
2028 20
2029 20
202F 20
2030 25
2033 22
2036 22
2039 3C
203A 3E
2041 2F
2043 2D
2044 2F
204E 2A
2052 25
2053 7E
205A 3A
205F 20
2070 4F
2071 69
2074 34
2075 35
2076 36
2077 37
2078 38
2079 39
207F 6E
2080 4F
2081 31
2082 32
2083 33
2084 34
2085 35
2086 36
2087 37
2088 38
2089 39
2090 61
2091 65
2092 6F
2093 78
2095 68
2096 6B
2097 6C
2098 6D
2099 6E
209A 70
209B 73
209C 74
20A8 52+73
2100 25
2101 25
2102 43
2103 43
2105 25
2106 25
2109 4F+46
210A 67
210B 48
210C 48
210D 48
210E 68
2110 4A
2111 4A
2112 4C
2113 6C
2115 4E
2116 4E+6F
2117 28+50+29
2118 50
2119 50
211A 51
211B 52
211C 52
211D 52
2120 28+53+4D+29
2121 54+45+4C
2122 28+54+4D+29
2124 5A
2128 33
212A 4B
212B 41
212C 42
212D 43
212E 65
212F 65
2130 45
2131 46
2133 4D
2134 6F
2139 69
213B 46+41+58
213C 6E
213D 79
2140 45
2145 44
2146 64
2147 65
2148 69
2149 6A
2160 49
2161 49+49
2162 49+49+49
2163 49+56
2164 56
2165 56+49
2166 56+49+49
2167 56+49+49+49
2168 49+58
2169 58
216A 58+49
216B 58+49+49
216C 4C
216D 43
216E 44
216F 4D
2170 69
2171 69+69
2172 69+69+69
2173 69+76
2174 76
2175 76+69
2176 76+69+69
2177 76+69+69+69
2178 69+78
2179 78
217A 78+69
217B 78+69+69
217C 4C
217D 63
217E 64
217F 6D
2208 45
220A 45
2211 45
2212 2D
2215 2F
2216 5C
2217 2A
2219 2E
221F 4C
2223 6C
2228 76
222B 53
222C 53+53
2236 3A
223C 7E
2282 43
22C1 76
22C3 55
22C5 2E
22FF 45
2373 69
2374 70
2375 77
2379 77
237A 61
23B8 4C
2460 31
2461 32
2462 33
2463 34
2464 35
2465 36
2466 37
2467 38
2468 39
2469 31+30
246A 31+31
246B 31+32
246C 31+33
246D 31+34
246E 31+35
246F 31+36
2470 31+37
2471 31+38
2472 31+39
2473 32+30
2474 28+31+29
2475 28+32+29
2476 28+33+29
2477 28+34+29
2478 28+35+29
2479 28+36+29
247A 28+37+29
247B 28+38+29
247C 28+39+29
247D 28+31+30+29
247E 28+31+31+29
247F 28+31+32+29
2480 28+31+33+29
2481 28+31+34+29
2482 28+31+35+29
2483 28+31+36+29
2484 28+31+37+29
2485 28+31+38+29
2486 28+31+39+29
2487 28+32+30+29
2488 31+2E
2489 32+2E
248A 33+2E
248B 34+2E
248C 35+2E
248D 36+2E
248E 37+2E
248F 38+2E
2490 39+2E
2491 31+30+2E
2492 31+31+2E
2493 31+32+2E
2494 31+33+2E
2495 31+34+2E
2496 31+35+2E
2497 31+36+2E
2498 31+37+2E
2499 31+38+2E
249A 31+39+2E
249B 32+30+2E
249C 61
249D 62
249E 63
249F 64
24A0 65
24A1 66
24A2 67
24A3 68
24A4 69
24A5 6A
24A6 6B
24A7 6C
24A8 6D
24A9 6E
24AA 6F
24AB 70
24AC 71
24AD 72
24AE 73
24AF 74
24B0 75
24B1 76
24B2 77
24B3 78
24B4 79
24B5 7A
24B6 41
24B7 42
24B8 43
24B9 44
24BA 45
24BB 46
24BC 47
24BD 48
24BE 49
24BF 4A
24C0 4B
24C1 4C
24C2 4D
24C3 4E
24C4 4F
24C5 50
24C6 51
24C7 52
24C8 53
24C9 54
24CA 55
24CB 56
24CC 57
24CD 58
24CE 59
24CF 5A
24D0 61
24D1 62
24D2 63
24D3 64
24D4 65
24D5 66
24D6 67
24D7 68
24D8 69
24D9 6A
24DA 6B
24DB 6C
24DC 6D
24DD 6E
24DE 6F
24DF 70
24E0 71
24E1 72
24E2 73
24E3 74
24E4 75
24E5 76
24E6 77
24E7 78
24E8 79
24E9 7A
24EA 4F
2571 2F
2573 78
25AE 4C
25AF 4C
25CC 6F
2686 6F
2687 6F
26E3 4F
2758 4C
2759 4C
275A 4C
2768 28
2769 29
276E 3C
276F 3E
2772 28
2773 29
2774 7B
2775 7D
27D9 54
2801 2E
2802 2E
2804 2E
2810 2E
2820 2E
2840 2E
2880 2E
28C0 2E+2E
292B 78
292C 78
2981 2E
29F5 5C
29F8 2F
29F9 5C
2A2F 78
2B2F 4F
2C60 4C
2C61 6C
2C62 4C
2C63 50
2C64 52
2C65 61
2C66 74
2C67 48
2C68 68
2C69 4B
2C6A 6B
2C6B 5A
2C6C 7A
2C6E 4D
2C71 76
2C72 57
2C73 77
2C74 76
2C78 65
2C7A 6F
2C7C 6A
2C7D 56
2C7E 53
2C7F 5A
2C85 72
2C8E 48
2C92 49
2C94 4B
2C95 6B
2C98 4D
2C9A 4E
2C9E 6F
2C9F 6F
2CA2 50
2CA3 70
2CA4 43
2CA5 63
2CA6 54
2CA8 59
2CAC 58
2CBA 2D
2CC6 2F
2CCA 39
2CCC 33
2CD0 4C
2CD2 36
2D38 56
2D39 45
2D4F 49
2D54 4F
2D5D 58
2E31 2E
2E33 2E
2F02 5C
2F03 2F
3000 20
3003 22
3007 4F
3014 28
3015 29
3033 2F
30FB 2E
31D3 2F
31D4 5C
3250 50+54+45
3251 32+31
3252 32+32
3253 32+33
3254 32+34
3255 32+35
3256 32+36
3257 32+37
3258 32+38
3259 32+39
325A 33+30
325B 33+31
325C 33+32
325D 33+33
325E 33+34
325F 33+35
32B1 33+36
32B2 33+37
32B3 33+38
32B4 33+39
32B5 34+30
32B6 34+31
32B7 34+32
32B8 34+33
32B9 34+34
32BA 34+35
32BB 34+36
32BC 34+37
32BD 34+38
32BE 34+39
32BF 35+30
32CC 48+67
32CD 65+72+67
32CE 65+56
32CF 4C+54+44
3371 68+50+61
3372 64+61
3373 41+55
3374 62+61+72
3375 6F+56
3376 70+63
3377 64+6D
3378 64+6D+32
3379 64+6D+33
337A 49+55
3380 70+41
3381 6E+41
3382 75+41
3383 6D+41
3384 6B+41
3385 4B+42
3386 4D+42
3387 47+42
3388 63+61+6C
3389 6B+63+61+6C
338A 70+46
338B 6E+46
338C 75+46
338D 75+67
338E 6D+67
338F 6B+67
3390 48+7A
3391 6B+48+7A
3392 4D+48+7A
3393 47+48+7A
3394 54+48+7A
3395 75+6C
3396 6D+6C
3397 64+6C
3398 6B+6C
3399 66+6D
339A 6E+6D
339B 75+6D
339C 6D+6D
339D 63+6D
339E 6B+6D
339F 6D+6D+32
33A0 63+6D+32
33A1 6D+32
33A2 6B+6D+32
33A3 6D+6D+33
33A4 63+6D+33
33A5 6D+33
33A6 6B+6D+33
33A8 6D+73+32
33A9 50+61
33AA 6B+50+61
33AB 4D+50+61
33AC 47+50+61
33AD 72+61+64
33B0 70+73
33B1 6E+73
33B2 75+73
33B3 6D+73
33B4 70+56
33B5 6E+56
33B6 75+56
33B7 6D+56
33B8 6B+56
33B9 4D+56
33BA 70+57
33BB 6E+57
33BC 75+57
33BD 6D+57
33BE 6B+57
33BF 4D+57
33C2 61+2E+6D+2E
33C3 42+71
33C4 63+63
33C5 63+64
33C7 43+6F+2E
33C8 64+42
33C9 47+79
33CA 68+61
33CB 48+50
33CC 69+6E
33CD 4B+4B
33CE 4B+4D
33CF 6B+74
33D0 6C+6D
33D1 6C+6E
33D2 6C+6F+67
33D3 6C+78
33D4 6D+62
33D5 6D+69+6C
33D6 6D+6F+6C
33D7 50+48
33D8 70+2E+6D+2E
33D9 50+50+4D
33DA 50+52
33DB 73+72
33DC 53+76
33DD 57+62
33FF 67+61+6C
4E36 5C
4E3F 2F
A4D0 42
A4D1 50
A4D2 64
A4D3 44
A4D4 54
A4D6 47
A4D7 4B
A4D9 4A
A4DA 43
A4DC 5A
A4DD 46
A4DF 4D
A4E0 4E
A4E1 4C
A4E2 53
A4E3 52
A4E6 56
A4E7 48
A4EA 57
A4EB 58
A4EC 59
A4EE 41
A4F0 45
A4F2 49
A4F3 4F
A4F4 55
A4F8 2E
A4FB 2E+2C
A4FD 3A
A4FF 3D
A60E 2A
A644 32
A731 73
A733 61+61
A740 4B
A741 6B
A742 4B
A743 6B
A744 4B
A745 6B
A748 4C
A749 6C
A74A 4F
A74B 6F
A74C 4F
A74D 6F
A750 50
A751 70
A752 50
A753 70
A754 50
A755 70
A756 51
A757 71
A758 51
A759 71
A75A 32
A75B 72
A75E 56
A75F 76
A76A 33
A76E 39
A778 26
A789 3A
A78E 6C
A78F 2E
A790 4E
A791 6E
A792 43
A793 43
A794 63
A795 68
A796 42
A797 62
A798 46
A799 66
A7A0 47
A7A1 67
A7A2 4B
A7A3 6B
A7A4 4E
A7A5 6E
A7A6 52
A7A7 66
A7A8 53
A7A9 73
A7AA 48
A7AD 4C
A7B2 4A
A7B6 77
A7B7 77
A7B8 55
A7B9 75
A7C4 43
A7C5 53
A7C6 5A
A7C7 44
A7C8 64
A7C9 53
A7CA 73
A7F2 43
A7F3 46
A7F4 51
A7F9 6F+65
A7FE 49
AB31 61+65
AB34 65
AB37 6C
AB38 6C
AB39 6C
AB3A 6D
AB3B 6E
AB3E 6F
AB47 72
AB49 72
AB4E 75
AB4F 75
AB52 75
AB56 78
AB57 78
AB58 78
AB59 78
AB5A 79
FB00 66+66
FB01 66+69
FB02 66+6C
FB03 66+66+69
FB04 66+66+6C
FB05 66+74
FB06 73+74
FB29 2B
FD3E 28
FD3F 29
FE30 3A
FE31 4C
FE32 4C
FE33 4C
FE34 4C
FE4D 5F
FE4E 5F
FE4F 5F
FE52 2E
FE58 2D
FE68 5C
FE69 24
FE6A 25
FE6B 40
FF01 21
FF02 22
FF03 23
FF04 24
FF05 25
FF06 26
FF0A 2A
FF0D 2D
FF0E 2E
FF0F 2F
FF10 4F
FF11 31
FF12 32
FF13 33
FF14 34
FF15 35
FF16 36
FF17 37
FF18 38
FF19 39
FF1A 3A
FF1B 3B
FF1F 3F
FF20 40
FF21 41
FF22 42
FF23 43
FF24 44
FF25 45
FF26 46
FF27 47
FF28 48
FF29 49
FF2A 4A
FF2B 4B
FF2C 4C
FF2D 4D
FF2E 4E
FF2F 4F
FF30 50
FF31 51
FF32 52
FF33 53
FF34 54
FF35 55
FF36 56
FF37 57
FF38 58
FF39 59
FF3A 5A
FF3B 5B
FF3C 5C
FF3D 5D
FF3E 5E
FF3F 5F
FF40 60
FF41 61
FF42 62
FF43 63
FF44 64
FF45 65
FF46 66
FF47 67
FF48 68
FF49 69
FF4A 6A
FF4B 6B
FF4C 4C
FF4D 6D
FF4E 6E
FF4F 6F
FF50 70
FF51 71
FF52 72
FF53 73
FF54 74
FF55 75
FF56 76
FF57 77
FF58 78
FF59 79
FF5A 7A
FF5B 7B
FF5D 7D
FF65 2E
FFE8 4C
107A5 71
10A50 2E
1BC0D 44
1D16D 2E
1D400 41
1D401 42
1D402 43
1D403 44
1D404 45
1D405 46
1D406 47
1D407 48
1D408 49
1D409 4A
1D40A 4B
1D40B 4C
1D40C 4D
1D40D 4E
1D40E 4F
1D40F 50
1D410 51
1D411 52
1D412 53
1D413 54
1D414 55
1D415 56
1D416 57
1D417 58
1D418 59
1D419 5A
1D41A 61
1D41B 62
1D41C 63
1D41D 64
1D41E 65
1D41F 66
1D420 67
1D421 68
1D422 69
1D423 6A
1D424 6B
1D425 6C
1D426 6D
1D427 6E
1D428 6F
1D429 70
1D42A 71
1D42B 72
1D42C 73
1D42D 74
1D42E 75
1D42F 76
1D430 77
1D431 78
1D432 79
1D433 7A
1D434 41
1D435 42
1D436 43
1D437 44
1D438 45
1D439 46
1D43A 47
1D43B 48
1D43C 49
1D43D 4A
1D43E 4B
1D43F 4C
1D440 4D
1D441 4E
1D442 4F
1D443 50
1D444 51
1D445 52
1D446 53
1D447 54
1D448 55
1D449 56
1D44A 57
1D44B 58
1D44C 59
1D44D 5A
1D44E 61
1D44F 62
1D450 63
1D451 64
1D452 65
1D453 66
1D454 67
1D456 69
1D457 6A
1D458 6B
1D459 6C
1D45A 6D
1D45B 6E
1D45C 6F
1D45D 70
1D45E 71
1D45F 72
1D460 73
1D461 74
1D462 75
1D463 76
1D464 77
1D465 78
1D466 79
1D467 7A
1D468 41
1D469 42
1D46A 43
1D46B 44
1D46C 45
1D46D 46
1D46E 47
1D46F 48
1D470 49
1D471 4A
1D472 4B
1D473 4C
1D474 4D
1D475 4E
1D476 4F
1D477 50
1D478 51
1D479 52
1D47A 53
1D47B 54
1D47C 55
1D47D 56
1D47E 57
1D47F 58
1D480 59
1D481 5A
1D482 61
1D483 62
1D484 63
1D485 64
1D486 65
1D487 66
1D488 67
1D489 68
1D48A 69
1D48B 6A
1D48C 6B
1D48D 6C
1D48E 6D
1D48F 6E
1D490 6F
1D491 70
1D492 71
1D493 72
1D494 73
1D495 74
1D496 75
1D497 76
1D498 77
1D499 78
1D49A 79
1D49B 7A
1D49C 41
1D49E 43
1D49F 44
1D4A2 47
1D4A5 4A
1D4A6 4B
1D4A9 4E
1D4AA 4F
1D4AB 50
1D4AC 51
1D4AE 53
1D4AF 54
1D4B0 55
1D4B1 56
1D4B2 57
1D4B3 58
1D4B4 59
1D4B5 5A
1D4B6 61
1D4B7 62
1D4B8 63
1D4B9 64
1D4BB 66
1D4BD 68
1D4BE 69
1D4BF 6A
1D4C0 6B
1D4C1 6C
1D4C2 6D
1D4C3 6E
1D4C5 70
1D4C6 71
1D4C7 72
1D4C8 73
1D4C9 74
1D4CA 75
1D4CB 76
1D4CC 77
1D4CD 78
1D4CE 79
1D4CF 7A
1D4D0 41
1D4D1 42
1D4D2 43
1D4D3 44
1D4D4 45
1D4D5 46
1D4D6 47
1D4D7 48
1D4D8 49
1D4D9 4A
1D4DA 4B
1D4DB 4C
1D4DC 4D
1D4DD 4E
1D4DE 4F
1D4DF 50
1D4E0 51
1D4E1 52
1D4E2 53
1D4E3 54
1D4E4 55
1D4E5 56
1D4E6 57
1D4E7 58
1D4E8 59
1D4E9 5A
1D4EA 61
1D4EB 62
1D4EC 63
1D4ED 64
1D4EE 65
1D4EF 66
1D4F0 67
1D4F1 68
1D4F2 69
1D4F3 6A
1D4F4 6B
1D4F5 6C
1D4F6 6D
1D4F7 6E
1D4F8 6F
1D4F9 70
1D4FA 71
1D4FB 72
1D4FC 73
1D4FD 74
1D4FE 75
1D4FF 76
1D500 77
1D501 78
1D502 79
1D503 7A
1D504 55
1D505 42
1D507 44
1D508 45
1D509 46
1D50A 47
1D50D 4A
1D50E 4B
1D50F 4C
1D510 4D
1D511 4E
1D512 4F
1D513 42
1D514 51
1D516 47
1D517 49
1D518 55
1D519 42
1D51A 57
1D51B 58
1D51C 4E
1D51E 61
1D51F 62
1D520 63
1D521 64
1D522 65
1D523 66
1D524 67
1D525 68
1D526 69
1D527 6A
1D528 6B
1D529 6C
1D52A 6D
1D52B 6E
1D52C 6F
1D52D 70
1D52E 71
1D52F 72
1D530 73
1D531 74
1D532 75
1D533 76
1D534 77
1D535 78
1D536 6E
1D537 33
1D538 41
1D539 42
1D53B 44
1D53C 45
1D53D 46
1D53E 47
1D540 49
1D541 4A
1D542 4B
1D543 4C
1D544 4D
1D546 4F
1D54A 53
1D54B 54
1D54C 55
1D54D 56
1D54E 57
1D54F 58
1D550 59
1D552 61
1D553 62
1D554 63
1D555 64
1D556 65
1D557 66
1D558 67
1D559 68
1D55A 69
1D55B 6A
1D55C 6B
1D55D 6C
1D55E 6D
1D55F 6E
1D560 6F
1D561 70
1D562 71
1D563 72
1D564 73
1D565 74
1D566 75
1D567 76
1D568 77
1D569 78
1D56A 79
1D56B 7A
1D56C 55
1D56D 42
1D56E 43
1D56F 44
1D570 45
1D571 46
1D572 47
1D573 48
1D574 49
1D575 4A
1D576 4B
1D577 4C
1D578 4D
1D579 4E
1D57A 4F
1D57B 42
1D57C 51
1D57D 52
1D57E 47
1D57F 49
1D580 55
1D581 42
1D582 57
1D583 58
1D584 4E
1D585 33
1D586 61
1D587 62
1D588 63
1D589 64
1D58A 65
1D58B 66
1D58C 67
1D58D 68
1D58E 69
1D58F 6A
1D590 6B
1D591 6C
1D592 6D
1D593 6E
1D594 6F
1D595 70
1D596 71
1D597 72
1D598 73
1D599 74
1D59A 75
1D59B 76
1D59C 77
1D59D 78
1D59E 79
1D59F 33
1D5A0 41
1D5A1 42
1D5A2 43
1D5A3 44
1D5A4 45
1D5A5 46
1D5A6 47
1D5A7 48
1D5A8 49
1D5A9 4A
1D5AA 4B
1D5AB 4C
1D5AC 4D
1D5AD 4E
1D5AE 4F
1D5AF 50
1D5B0 51
1D5B1 52
1D5B2 53
1D5B3 54
1D5B4 55
1D5B5 56
1D5B6 57
1D5B7 58
1D5B8 59
1D5B9 5A
1D5BA 61
1D5BB 62
1D5BC 63
1D5BD 64
1D5BE 65
1D5BF 66
1D5C0 67
1D5C1 68
1D5C2 69
1D5C3 6A
1D5C4 6B
1D5C5 6C
1D5C6 6D
1D5C7 6E
1D5C8 6F
1D5C9 70
1D5CA 71
1D5CB 72
1D5CC 73
1D5CD 74
1D5CE 75
1D5CF 76
1D5D0 77
1D5D1 78
1D5D2 79
1D5D3 7A
1D5D4 41
1D5D5 42
1D5D6 43
1D5D7 44
1D5D8 45
1D5D9 46
1D5DA 47
1D5DB 48
1D5DC 49
1D5DD 4A
1D5DE 4B
1D5DF 4C
1D5E0 4D
1D5E1 4E
1D5E2 4F
1D5E3 50
1D5E4 51
1D5E5 52
1D5E6 53
1D5E7 54
1D5E8 55
1D5E9 56
1D5EA 57
1D5EB 58
1D5EC 59
1D5ED 5A
1D5EE 61
1D5EF 62
1D5F0 63
1D5F1 64
1D5F2 65
1D5F3 66
1D5F4 67
1D5F5 68
1D5F6 69
1D5F7 6A
1D5F8 6B
1D5F9 6C
1D5FA 6D
1D5FB 6E
1D5FC 6F
1D5FD 70
1D5FE 71
1D5FF 72
1D600 73
1D601 74
1D602 75
1D603 76
1D604 77
1D605 78
1D606 79
1D607 7A
1D608 41
1D609 42
1D60A 43
1D60B 44
1D60C 45
1D60D 46
1D60E 47
1D60F 48
1D610 49
1D611 4A
1D612 4B
1D613 4C
1D614 4D
1D615 4E
1D616 4F
1D617 50
1D618 51
1D619 52
1D61A 53
1D61B 54
1D61C 55
1D61D 56
1D61E 57
1D61F 58
1D620 59
1D621 5A
1D622 61
1D623 62
1D624 63
1D625 64
1D626 65
1D627 66
1D628 67
1D629 68
1D62A 69
1D62B 6A
1D62C 6B
1D62D 6C
1D62E 6D
1D62F 6E
1D630 6F
1D631 70
1D632 71
1D633 72
1D634 73
1D635 74
1D636 75
1D637 76
1D638 77
1D639 78
1D63A 79
1D63B 7A
1D63C 41
1D63D 42
1D63E 43
1D63F 44
1D640 45
1D641 46
1D642 47
1D643 48
1D644 49
1D645 4A
1D646 4B
1D647 4C
1D648 4D
1D649 4E
1D64A 4F
1D64B 50
1D64C 51
1D64D 52
1D64E 53
1D64F 54
1D650 55
1D651 56
1D652 57
1D653 58
1D654 59
1D655 5A
1D656 61
1D657 62
1D658 63
1D659 64
1D65A 65
1D65B 66
1D65C 67
1D65D 68
1D65E 69
1D65F 6A
1D660 6B
1D661 6C
1D662 6D
1D663 6E
1D664 6F
1D665 70
1D666 71
1D667 72
1D668 73
1D669 74
1D66A 75
1D66B 76
1D66C 77
1D66D 78
1D66E 79
1D66F 7A
1D670 41
1D671 42
1D672 43
1D673 44
1D674 45
1D675 46
1D676 47
1D677 48
1D678 49
1D679 4A
1D67A 4B
1D67B 4C
1D67C 4D
1D67D 4E
1D67E 4F
1D67F 50
1D680 51
1D681 52
1D682 53
1D683 54
1D684 55
1D685 56
1D686 57
1D687 58
1D688 59
1D689 5A
1D68A 61
1D68B 62
1D68C 63
1D68D 64
1D68E 65
1D68F 66
1D690 67
1D691 68
1D692 69
1D693 6A
1D694 6B
1D695 6C
1D696 6D
1D697 6E
1D698 6F
1D699 70
1D69A 71
1D69B 72
1D69C 73
1D69D 74
1D69E 75
1D69F 76
1D6A0 77
1D6A1 78
1D6A2 79
1D6A3 7A
1D6A4 69
1D6A5 6A
1D6A8 41
1D6A9 42
1D6AC 45
1D6AD 5A
1D6AE 48
1D6B0 49
1D6B1 4B
1D6B3 4D
1D6B4 4E
1D6B6 4F
1D6B8 50
1D6BB 54
1D6BC 59
1D6BE 58
1D6C2 61
1D6C4 79
1D6CA 69
1D6CB 6B
1D6CE 76
1D6D0 6F
1D6D1 6E
1D6D2 70
1D6D4 6F
1D6D5 74
1D6D6 75
1D6DA 77
1D6DE 6B
1D6E0 70
1D6E1 77
1D6E2 41
1D6E3 42
1D6E6 45
1D6E7 5A
1D6E8 48
1D6EA 49
1D6EB 4B
1D6ED 4D
1D6EE 4E
1D6F0 4F
1D6F2 50
1D6F5 54
1D6F6 59
1D6F8 58
1D6FC 61
1D6FE 79
1D704 69
1D705 6B
1D708 76
1D70A 6F
1D70B 6E
1D70C 70
1D70E 6F
1D70F 74
1D710 75
1D714 77
1D718 6B
1D71A 70
1D71B 77
1D71C 41
1D71D 42
1D720 45
1D721 5A
1D722 48
1D724 49
1D725 4B
1D727 4D
1D728 4E
1D72A 4F
1D72C 50
1D72F 54
1D730 59
1D732 58
1D736 61
1D738 79
1D73E 69
1D73F 6B
1D742 76
1D744 6F
1D745 6E
1D746 70
1D748 6F
1D749 74
1D74A 75
1D74E 77
1D752 6B
1D754 70
1D755 77
1D756 41
1D757 42
1D75A 45
1D75B 5A
1D75C 48
1D75E 49
1D75F 4B
1D761 4D
1D762 4E
1D764 4F
1D766 50
1D769 54
1D76A 59
1D76C 58
1D770 61
1D772 79
1D778 69
1D779 6B
1D77C 76
1D77E 6F
1D77F 6E
1D780 70
1D782 6F
1D783 74
1D784 75
1D788 77
1D78C 6B
1D78E 70
1D78F 77
1D790 41
1D791 42
1D794 45
1D795 5A
1D796 48
1D798 49
1D799 4B
1D79B 4D
1D79C 4E
1D79E 4F
1D7A0 50
1D7A3 54
1D7A4 59
1D7A6 58
1D7AA 61
1D7AC 79
1D7B2 69
1D7B3 6B
1D7B6 76
1D7B8 6F
1D7B9 6E
1D7BA 70
1D7BC 6F
1D7BD 74
1D7BE 75
1D7C2 77
1D7C6 6B
1D7C8 70
1D7C9 77
1D7CA 46
1D7CE 4F
1D7CF 31
1D7D0 32
1D7D1 33
1D7D2 34
1D7D3 35
1D7D4 36
1D7D5 37
1D7D6 38
1D7D7 39
1D7D8 4F
1D7D9 31
1D7DA 32
1D7DB 33
1D7DC 34
1D7DD 35
1D7DE 36
1D7DF 37
1D7E0 38
1D7E1 39
1D7E2 4F
1D7E3 31
1D7E4 32
1D7E5 33
1D7E6 34
1D7E7 35
1D7E8 36
1D7E9 37
1D7EA 38
1D7EB 39
1D7EC 4F
1D7ED 31
1D7EE 32
1D7EF 33
1D7F0 34
1D7F1 35
1D7F2 36
1D7F3 37
1D7F4 38
1D7F5 39
1D7F6 4F
1D7F7 31
1D7F8 32
1D7F9 33
1D7FA 34
1D7FB 35
1D7FC 36
1D7FD 37
1D7FE 38
1D7FF 39
1DF09 74
1DF11 6C
1DF13 6C
1DF16 72
1DF1A 69
1DF1B 6F
1DF1D 63
1DF1E 73
1DF25 64
1DF26 6C
1DF27 6E
1DF28 72
1DF29 73
1DF2A 74
1F100 30+2E
1F101 30+2C
1F102 31+2C
1F103 32+2C
1F104 33+2C
1F105 34+2C
1F106 35+2C
1F107 36+2C
1F108 37+2C
1F109 38+2C
1F10A 39+2C
1F110 41
1F111 42
1F112 43
1F113 44
1F114 45
1F115 46
1F116 47
1F117 48
1F118 49
1F119 4A
1F11A 4B
1F11B 4C
1F11C 4D
1F11D 4E
1F11E 4F
1F11F 50
1F120 51
1F121 52
1F122 53
1F123 54
1F124 55
1F125 56
1F126 57
1F127 58
1F128 59
1F129 5A
1F12A 53
1F12B 43
1F12C 52
1F12D 43+44
1F12E 57+5A
1F130 41
1F131 42
1F132 43
1F133 44
1F134 45
1F135 46
1F136 47
1F137 48
1F138 49
1F139 4A
1F13A 4B
1F13B 4C
1F13C 4D
1F13D 4E
1F13E 4F
1F13F 50
1F140 51
1F141 52
1F142 53
1F143 54
1F144 55
1F145 56
1F146 57
1F147 58
1F148 59
1F149 5A
1F14A 48+56
1F14B 4D+56
1F14C 53+44
1F14D 53+53
1F14E 50+50+56
1F14F 57+43
1F16A 4D+43
1F16B 4D+44
1F16C 4D+52
1F190 44+4A
1FBF0 4F
1FBF1 31
1FBF2 32
1FBF3 33
1FBF4 34
1FBF5 35
1FBF6 36
1FBF7 37
1FBF8 38
1FBF9 39
