=pod

=head1 NAME

Wrapper class around the wireguard configuration files

=head1 SYNOPSIS

 use WGmeta::Wireguard::Wrapper::Config;
 my $wg_meta = WGmeta::Wireguard::Wrapper::Config->new('<path to wireguard configuration>');


=head1 DESCRIPTION

This class serves as wrapper around the Wireguard configurations files.
It is able to parse, modify, add and write Wireguard .conf files. In addition, support for metadata is built in. As a small
bonus, the parser and encoder are exported ar usable as standalone methods

=head1 EXAMPLES

 use WGmeta::Wireguard::Wrapper::Config;
 my $wg-meta = WGmeta::Wireguard::Wrapper::Config->new('<path to wireguard configuration>');

 # set an attribute (non wg-meta attributes forwarded to the original `wg set` command)
 wg_meta->set('wg0', 'WG_0_PEER_A_PUBLIC_KEY', '<attribute_name>', '<attribute_value>');

 # set an alias for a peer
 wg_meta->set('wg0', 'WG_0_PEER_A_PUBLIC_KEY', 'Alias', 'some_fancy_alias');

 # disable peer (this comments out the peer in the configuration file
 wg_meta->disable_by_alias('wg0', 'some_fancy_alias');

 # write config (if parameter is set to True, the config is overwritten, if set to False the resulting file is suffixed with '_dryrun'
 wg_meta->commit(1);

=head1 METHODS

=cut

use v5.22;
package WGmeta::Wireguard::Wrapper::Config;
use strict;
use warnings;
use experimental 'signatures';
use WGmeta::Utils;
use Data::Dumper;
use Time::Piece;
use File::Basename;
use WGmeta::Wireguard::Wrapper::Bridge;
use Digest::MD5 qw(md5);

use base 'Exporter';
our @EXPORT = qw(read_wg_configs create_wg_config);

use constant FALSE => 0;
use constant TRUE => 1;

# constants for states of the config parser
use constant IS_EMPTY => -1;
use constant IS_COMMENT => 0;
use constant IS_WG_META => 1;
use constant IS_SECTION => 2;
use constant IS_NORMAL => 3;


=head3 new($wireguard_home [, $wg_meta_prefix = '#+', $wg_meta_disabled_prefix = '#-', $ref_hash_additional_attrs])

Creates a new instance of this class. Default wg-meta attributes: 'Name' and 'Alias'.

B<Parameters>

=over 1

=item *

C<$wireguard_home> Path to Wireguard configuration files. Make sure the path ends with a `/`.

=item *

C<[, $wg_meta_prefix]> A custom wg-meta comment prefix, has to begin with either `;` or `#`.
It is recommended to not change this setting, especially in a already deployed installation.

=item *

C<[, $wg_meta_disabled_prefix]> A custom prefix for the commented out (disabled) sections,
has to begin with either `;` or `#` and must not be equal with C<$wg_meta_prefix>! (This is enforced and an exception is thrown if violated)
It is recommended to not change this setting, especially in a ready deployed installation.

=item *

C<[, $ref_hash_additional_attrs]> A reference to a list containing additional wg-meta attributes, the intersect of this list
with the default attributes defines the "valid wg-meta attributes".

=back

B<Returns>

An instance of Wrapper::Config

=cut
sub new($class, $wireguard_home, $wg_meta_prefix = '#+', $wg_meta_disabled_prefix = '#-', $ref_hash_additional_attrs = undef) {
    my %default_attrs = (
        'Name'     => undef,
        'Alias'    => undef,
        'Disabled' => undef
    );
    if (defined $ref_hash_additional_attrs) {
        map {$default_attrs{$_} = undef} keys %{$ref_hash_additional_attrs};
    }
    else {
        $ref_hash_additional_attrs = \%default_attrs;
    }

    if ($wg_meta_prefix eq $wg_meta_disabled_prefix) {
        die '`$wg_meta_prefix` and `$wg_meta_disabled_prefix` have to be different';
    }

    my $self = {
        'wireguard_home'          => $wireguard_home,
        'wg_meta_prefix'          => $wg_meta_prefix,
        'wg_meta_disabled_prefix' => $wg_meta_disabled_prefix,
        'valid_attrs'             => $ref_hash_additional_attrs,
        'has_changed'             => FALSE,
        'parsed_config'           => read_wg_configs($wireguard_home, $wg_meta_prefix, $wg_meta_disabled_prefix)
    };

    bless $self, $class;
    return $self;
}

=head3 set($interface, $identifier, $attribute, $value [, $allow_non_meta = FALSE])

Sets a value on a specific interface section.

B<Parameters>

=over 1

=item *

C<$interface> Valid interface identifier (e.g 'wg0')

=item *

C<$identifier> If the target section is a peer, this is usually the public key of this peer. If target is an interface,
its again the interface name

=item *

C<$attribute> Attribute name (Case does not not matter)

=item *

C<[, $allow_non_meta = FALSE]> If set to TRUE, non wg-meta attributes are not forwarded to `wg set`.
However be extra careful when using this, there is no validation!

=back

B<Raises>

Exception if either the interface or identifier is invalid

B<Returns>

None

=cut
sub set($self, $interface, $identifier, $attribute, $value, $allow_non_meta = FALSE) {
    $attribute = ucfirst $attribute;
    if ($self->_is_valid_interface($interface)) {
        if ($self->_is_valid_identifier($interface, $identifier)) {
            if ($self->_decide_attr_type($attribute) == IS_WG_META) {
                unless (exists $self->{parsed_config}{$interface}{$identifier}{$self->{wg_meta_prefix} . $attribute}) {
                    # the attribute does not (yet) exist in the configuration, lets add it to the list
                    push @{$self->{parsed_config}{$interface}{$identifier}{order}}, $self->{wg_meta_prefix} . $attribute;
                }
                # the attribute does already exist and therefore we just set it to the new value
                $self->{parsed_config}{$interface}{$identifier}{$self->{wg_meta_prefix} . $attribute} = $value;
                $self->{has_changed} = TRUE;
            }
            else {
                if ($allow_non_meta == TRUE) {
                    unless (exists $self->{parsed_config}{$interface}{$identifier}{$attribute}) {
                        # the attribute does not (yet) exist in the configuration, lets add it to the list
                        push @{$self->{parsed_config}{$interface}{$identifier}{order}}, $attribute;
                    }
                    # the attribute does already exist and therefore we just set it to the new value
                    $self->{parsed_config}{$interface}{$identifier}{$attribute} = $value;
                    $self->{has_changed} = TRUE;
                }
                else {
                    _forward($interface, $identifier, $attribute, $value)
                }
            }
        }
        else {
            die "Invalid identifier `$identifier` for interface `$interface`";
        }
    }
    else {
        die "Invalid interface name `$interface`";
    }

}

=head3 set_by_alias($interface, $alias, $attribute, $value)

Same as L</set($interface, $identifier, $attribute, $value [, $allow_non_meta = FALSE])> - just with alias support.

B<Raises>

Exception if alias is invalid

=cut
sub set_by_alias($self, $interface, $alias, $attribute, $value) {
    my $identifier = $self->translate_alias($interface, $alias);
    $self->set($interface, $identifier, $attribute, $value);
}

=head3 disable($interface, $identifier)

Disables a peer

B<Parameters>

=over 1

=item *

C<$interface> Valid interface name (e.g 'wg0').

=item *

C<$identifier> A valid identifier: If the target section is a peer, this is usually the public key of this peer. If target is an interface,
its again the interface name.

=back

B<Returns>

None

=cut
sub disable($self, $interface, $identifier,) {
    $self->_toggle($interface, $identifier, TRUE);
}

=head3 enable($interface, $identifier)

Inverse method if L</disable($interface, $identifier)>

=cut
sub enable($self, $interface, $identifier) {
    $self->_toggle($interface, $identifier, FALSE);
}

=head3 disable_by_alias($interface, $alias)

Same as L</disable($interface, $identifier)> just with alias support

B<Raises>

Exception if alias is invalid

=cut
sub disable_by_alias($self, $interface, $alias,) {
    $self->_toggle($interface, $self->translate_alias($interface, $alias), FALSE);
}

=head3 disable_by_alias($interface, $alias)

Same as L</enable($interface, $identifier)>ust with alias support

B<Raises>

Exception if alias is invalid

=cut
sub enable_by_alias($self, $interface, $alias,) {
    $self->_toggle($interface, $self->translate_alias($interface, $alias), TRUE);
}

# internal toggle method (DRY)
sub _toggle($self, $interface, $identifier, $enable) {
    if (exists $self->{parsed_config}{$interface}{$identifier}{Disabled}) {
        if ($self->{parsed_config}{$interface}{$identifier}{Disabled} == "$enable") {
            warn "Section `$identifier` in `$interface` is already $enable";
        }
    }
    $self->set($interface, $identifier, 'Disabled', $enable);
}

# internal forward method, as for now, this is just a stub
sub _forward($interface, $identifier, $attribute, $value) {
    # this is just as stub
    print("Forwarded to wg original wg command: `$attribute = $value`");
}

# internal method to decide if an attribute is a wg-meta attribute
sub _decide_attr_type($self, $attr_name) {
    if (exists $self->{valid_attrs}{ucfirst $attr_name}) {
        return IS_WG_META;
    }
    else {
        return IS_NORMAL;
    }
}

# internal method to check whether an interface is valid
sub _is_valid_interface($self, $interface) {
    return (exists $self->{parsed_config}{$interface});
}

# internal method to check whether an identifier is valid inside an interface
sub _is_valid_identifier($self, $interface, $identifier) {
    return (exists $self->{parsed_config}{$interface}{$identifier});
}

=head3 translate_alias($interface, $alias)

Translates an alias to a valid identifier.

B<Parameters>

=over 1

=item *

C<$interface> A valid interface name (e.g 'wg0').

=item *

C<$alias> An alias to translate

=back

B<Raises>

Exception if alias is invalid

B<Returns>

A valid identifier.

=cut
sub translate_alias($self, $interface, $alias) {
    if (exists $self->{parsed_config}{$interface}{alias_map}{$alias}) {
        return $self->{parsed_config}{$interface}{alias_map}{$alias};
    }
    else {
        die "Invalid alias `$alias` in interface $interface";
    }
}

=head3 read_wg_configs($wireguard_home, $wg_meta_prefix, $disabled_prefix)

Parses all configuration files in C<$wireguard_home> matching I<.*\.conf$> and returns a hash with the following structure:

    {
        'interface_name' => {
            'section_order' => <list_of_available_section_identifiers>,
            'alias_map'     => <mapping_alias_to_identifier>,
            'checksum'      => <calculated_checksum_of_this_interface_config>,
            'a_identifier'    => {
                'type'  => <'Interface' or 'Peer'>,
                'order' => <list_of_attributes_in_their_original_order>,
                'attr0' => <value_of_attr0>,
                'attrN' => <value_of_attrN>
            },
            'an_other_identifier => {
                [...]
            }
        },
        'an_other_interface' => {
            [...]
        }
    }

B<Remarks>

=over 1

=item *

This method can be used as stand-alone together with the corresponding L</create_wg_config($ref_interface_config, $wg_meta_prefix, $disabled_prefix [, $plain = FALSE])>.

=item *

If the section is of type 'Peer' the identifier equals to its public-key, otherwise its the interface name again

=item *

wg-meta attributes are always prefixed with C<$wg_met_prefix>.

=item *

If a section is marked as "disabled", this is represented in the attribute I<$wg_meta_prefix. 'Disabled' >.
However, does only exist if this section has been enabled/disabled once.


=back


B<Parameters>

=over 1

=item *

C<$wireguard_home> Path to wireguard configuartion files

=item *

C<$wg_meta_prefix> wg-meta prefix. Must start with '#' or ';'

=item *

C<$disabled_prefix> disabled prefix. Must start with '#' or ';'

=back

B<Raises>

An exceptions if:

=over 1

=item *

If the C<$wireguard_home> directory does not contain any matching config file.

=item *

If a config files is not readable.

=item *

If the parser ends up in an invalid state (e.g a section without information).

=back

A warning:

=over 1

=item *

On a checksum mismatch

=back

B<Returns>

A reference to a hash with the structure described above.

=cut
sub read_wg_configs($wireguard_home, $wg_meta_prefix, $disabled_prefix) {
    my @config_files = read_dir($wireguard_home, qr/.*\.conf$/);

    if (@config_files == 0) {
        die "No matching interface configuration(s) in " . $wireguard_home;
    }

    # create file-handle
    my $parsed_wg_config = {};
    for my $config_path (@config_files) {

        # read interface name
        my $i_name = basename($config_path);
        $i_name =~ s/\.conf//g;
        open my $fh, '<', $config_path or die "Could not open config file at $config_path";

        my %alias_map;
        my $current_state = -1;

        # state variables
        my $STATE_INIT_DONE = FALSE;
        my $STATE_READ_SECTION = FALSE;
        my $STATE_READ_ID = FALSE;
        my $STATE_EMPTY_SECTION = TRUE;
        my $STATE_READ_ALIAS = FALSE;

        # data of current section
        my $section_type;
        my $is_disabled = FALSE;
        my $comment_counter = 0;
        my $identifier;
        my $alias;
        my $section_data = {};
        my $checksum = '';
        my @section_data_order;
        my @section_order;

        while (my $line = <$fh>) {
            $current_state = _decide_state($line, $wg_meta_prefix, $disabled_prefix);

            # remove disabled prefix if any
            $line =~ s/^$disabled_prefix//g;

            if ($current_state == -1) {
                # empty line
            }
            elsif ($current_state == IS_SECTION) {
                # strip-off [] and whitespaces
                $line =~ s/^\[|\]\s*$//g;
                if (_is_valid_section($line) == TRUE) {
                    if ($STATE_EMPTY_SECTION == TRUE && $STATE_INIT_DONE == TRUE) {
                        die 'Found empty section, aborting';
                    }
                    else {
                        $STATE_READ_SECTION = TRUE;

                        if ($STATE_INIT_DONE == TRUE) {
                            # we are at the end of a section and therefore we can store the data

                            # first check if we read an private or public-key
                            if ($STATE_READ_ID == FALSE) {
                                die 'Section without identifying information found (Private -or PublicKey field)'
                            }
                            else {
                                $STATE_READ_ID = FALSE;
                                $STATE_EMPTY_SECTION = TRUE;
                                $parsed_wg_config->{$i_name}{$identifier} = $section_data;
                                $parsed_wg_config->{$i_name}{$identifier}{type} = $section_type;

                                # we have to use a copy of the array here - otherwise the reference stays the same in all sections.
                                $parsed_wg_config->{$i_name}{$identifier}{order} = [ @section_data_order ];
                                push @section_order, $identifier;

                                # reset vars
                                $section_data = {};
                                $is_disabled = FALSE;
                                @section_data_order = ();
                                $section_type = $line;
                                if ($STATE_READ_ALIAS == TRUE) {
                                    $alias_map{$alias} = $identifier;
                                    $STATE_READ_ALIAS = FALSE;
                                }
                            }
                        }
                        $section_type = $line;
                        $STATE_INIT_DONE = TRUE;
                    }
                }
                else {
                    die "Invalid section found: $line";
                }
            }
            # skip comments before sections -> we replace these with our header anyways...
            elsif ($current_state == IS_COMMENT) {
                unless ($STATE_INIT_DONE == FALSE) {
                    my $comment_id = "comment_" . $comment_counter++;
                    push @section_data_order, $comment_id;

                    $line =~ s/^\s+|\s+$//g;
                    $section_data->{$comment_id} = $line;
                }
            }
            elsif ($current_state == IS_WG_META) {
                # a special wg-meta attribute
                if ($STATE_INIT_DONE == FALSE) {
                    # this is already a wg-meta config and therefore we expect a checksum
                    (undef, $checksum) = split_and_trim($line, "=");
                }
                else {
                    if ($STATE_READ_SECTION == TRUE) {
                        $STATE_EMPTY_SECTION = FALSE;
                        my ($attr_name, $attr_value) = split_and_trim($line, "=");
                        if ($attr_name eq $wg_meta_prefix . "Alias") {
                            if (exists $alias_map{$attr_value}) {
                                die "Alias '$attr_value' already exists, aborting";
                            }
                            $STATE_READ_ALIAS = TRUE;
                            $alias = $attr_value;
                        }
                        push @section_data_order, $attr_name;
                        $section_data->{$attr_name} = $attr_value;
                    }
                    else {
                        die 'Attribute without a section encountered, aborting';
                    }
                }
            }
            else {
                # normal attribute
                if ($STATE_READ_SECTION == TRUE) {
                    $STATE_EMPTY_SECTION = FALSE;
                    my ($attr_name, $attr_value) = split_and_trim($line, '=');
                    if (_is_identifying($attr_name)) {
                        $STATE_READ_ID = TRUE;
                        if ($section_type eq 'Interface') {
                            $identifier = $i_name;
                        }
                        else {
                            $identifier = $attr_value;
                        }

                    }
                    push @section_data_order, $attr_name;
                    $section_data->{$attr_name} = $attr_value;
                }
                else {
                    die 'Attribute without a section encountered, aborting';
                }
            }
        }
        # store last section
        if ($STATE_READ_ID == FALSE) {
            die 'Section without identifying information found (Private -or PublicKey field'
        }
        else {
            $parsed_wg_config->{$i_name}{$identifier} = $section_data;
            $parsed_wg_config->{$i_name}{$identifier}{type} = $section_type;
            $parsed_wg_config->{$i_name}{checksum} = $checksum;
            $parsed_wg_config->{$i_name}{section_order} = \@section_order;
            $parsed_wg_config->{$i_name}{alias_map} = \%alias_map;

            $parsed_wg_config->{$i_name}{$identifier}{order} = \@section_data_order;
            push @section_order, $identifier;
            if ($STATE_READ_ALIAS == TRUE) {
                $alias_map{$alias} = $identifier;
            }
        }
        #print Dumper(\%alias_map);
        #print Dumper(\@section_order);
        #print Dumper($parsed_wg_config);
        close $fh;
        # checksum
        my $current_hash = _compute_checksum(create_wg_config($parsed_wg_config->{$i_name}, $wg_meta_prefix, $disabled_prefix, TRUE));
        unless ("$current_hash" eq $checksum) {
            warn "Config `$i_name.conf` has been changed by an other program or user. This is just a warning.";
        }
    }

    return ($parsed_wg_config);
}

# internal method to decide that current state using a line of input
sub _decide_state($line, $comment_prefix, $disabled_prefix) {
    #remove leading and tailing white space
    $line =~ s/^\s+|\s+$//g;
    for ($line) {
        /^$/ && return IS_EMPTY;
        /^\[/ && return IS_SECTION;
        /^\Q${comment_prefix}/ && return IS_WG_META;
        /^\Q${disabled_prefix}/ && do {
            $line =~ s/^$disabled_prefix//g;
            # lets do a little bit of recursion here ;)
            return _decide_state($line, $comment_prefix, $disabled_prefix);
        };
        /^#/ && return IS_COMMENT;
        return IS_NORMAL;
    }
}

# internal method to whether a section has a valid type
sub _is_valid_section($section) {
    return {
        Peer      => 1,
        Interface => 1
    }->{$section};
}

# internal method to check if an attribute fulfills identifying properties
sub _is_identifying($attr_name) {
    return {
        PrivateKey => 1,
        PublicKey  => 1
    }->{$attr_name};
}

=head3 split_and_trim($line, $separator)

Utility method to split and trim a string separated by C<$separator>.

B<Parameters>

=over 1

=item *

C<$line> Input string (e.g 'This = That   ')

=item *

C<$separator> String separator (e.v '=')

=back

B<Returns>

Two strings. With example values given in the parameters this would be 'This' and 'That'.

=cut
sub split_and_trim($line, $separator) {
    return map {s/^\s+|\s+$//g;
        $_} split $separator, $line, 2;
}

=head3 create_wg_config($ref_interface_config, $wg_meta_prefix, $disabled_prefix [, $plain = FALSE])

Turns a reference of interface-config hash (just a single interface)
(as defined in L</read_wg_configs($wireguard_home, $wg_meta_prefix, $disabled_prefix)>) back into a wireguard config.

B<Parameters>

=over 1

=item *

C<$ref_interface_config> Reference to hash containing B<one> interface config.

=item *

C<$wg_meta_prefix> Has to start with a '#' or ';' character and is optimally the
same as in L</read_wg_configs($wireguard_home, $wg_meta_prefix, $disabled_prefix)>

=item *

C<$wg_meta_prefix> Same restrictions as parameter C<$wg_meta_prefix>

=item *

C<[, $plain = FALSE]> If set to true, no header is added (useful for checksum calculation)

=back

B<Returns>

A string, ready to be written down as a config file.

=cut
sub create_wg_config($ref_interface_config, $wg_meta_prefix, $disabled_prefix, $plain = FALSE) {
    my $new_config = "\n";

    for my $identifier (@{$ref_interface_config->{section_order}}) {
        if (_is_disabled($ref_interface_config->{$identifier}, $wg_meta_prefix . "Disabled")) {
            $new_config .= $disabled_prefix;
        }
        # write down [section_type]
        $new_config .= "[$ref_interface_config->{$identifier}{type}]\n";
        for my $key (@{$ref_interface_config->{$identifier}{order}}) {
            if (_is_disabled($ref_interface_config->{$identifier}, $wg_meta_prefix . "Disabled")) {
                $new_config .= $disabled_prefix;
            }
            if (substr($key, 0, 7) eq 'comment') {
                $new_config .= $ref_interface_config->{$identifier}{$key} . "\n";
            }
            else {
                $new_config .= $key . " = " . $ref_interface_config->{$identifier}{$key} . "\n";
            }
        }
        $new_config .= "\n";
    }
    if ($plain == FALSE) {
        my $new_hash = _compute_checksum($new_config);
        my $config_header =
            "# This config is generated and maintained by wg-meta.
# It is strongly recommended to edit this config only through a supporting wg-meta
# implementation (e.g the wg-meta cli interface)
#
# Changes to this header are always overwritten, you can add normal comments in [Peer] and [Interface] section though.
#
# Support and issue tracker: https://github.com/sirtoobii/wg-meta
#+Checksum = $new_hash
";

        return $config_header . $new_config;
    }
    else {
        return $new_config;
    }
}

=head3 commit([$is_hot_config = FALSE])

Writes down the parsed config to the wireguard configuration folder

B<Parameters>

=over 1

=item

C<[$is_hot_config = FALSE])> If set to TRUE, the existing configuration is overwritten. Otherwise,
the suffix '_dryrun' is appended to the filename

=back

B<Raises>

Exception if: Folder or file is not writeable

B<Returns>

None

=cut
sub commit($self, $is_hot_config = FALSE) {
    for my $interface (keys %{$self->{parsed_config}}) {
        my $new_config = create_wg_config($self->{parsed_config}{$interface}, $self->{wg_meta_prefix}, $self->{wg_meta_disabled_prefix});
        my $fh;
        if ($is_hot_config == TRUE) {
            open $fh, '>', $self->{wireguard_home} . $interface . '.conf' or die $!;
        }
        else {
            open $fh, '>', $self->{wireguard_home} . $interface . '.conf_dryrun' or die $!;
        }
        # write down to file
        print $fh $new_config;
        close $fh;
    }
}

# internal method to check if a section is disabled
sub _is_disabled($ref_parsed_config_section, $key) {
    if (exists $ref_parsed_config_section->{$key}) {
        return $ref_parsed_config_section->{$key} == TRUE;
    }
    return FALSE;
}

# internal method to calculate a checksum (md5) of a string. Output is a 4-byte integer
sub _compute_checksum($input) {
    my $str = substr(md5($input), 0, 4);
    return unpack 'L', $str; # Convert to 4-byte integer
}

=head3 get_interface_list()

Return a list of all interfaces

B<Returns>

A list of all valid interface names.

=cut
sub get_interface_list($self) {
    return keys %{$self->{parsed_config}};
}

=head3 get_interface_section($interface, $identifier)

Returns a hash representing a section of a given interface

B<Parameters>

=over 1

=item *

C<$interface> Valid interface name

=item *

C<$identifier> Valid section identifier

=back

B<Returns>

A hash containing the requested section. If the requested section/interface is not present, an empty hash is returned.

=cut
sub get_interface_section($self, $interface, $identifier) {
    if (exists $self->{parsed_config}{$interface}{$identifier}) {
        return %{$self->{parsed_config}{$interface}{$identifier}};
    }
    else {
        return ();
    }
}

=head3 get_section_list($interface)

Returns a list of valid sections of an interface (ordered as in the original config file).

B<Parameters>

=over 1

=item *

C<$interface> A valid interface name

=back

B<Returns>

A list of all sections of an interface. If interface is not present, an empty list is returned.

=cut
sub get_section_list($self, $interface) {
    if (exists $self->{parsed_config}{$interface}) {
        return @{$self->{parsed_config}{$interface}{section_order}};
    }
    else {
        return {};
    }
}

sub get_wg_meta_prefix($self) {
    return $self->{wg_meta_prefix};
}

sub get_disabled_prefix($self) {
    return $self->{wg_meta_disabled_prefix};
}

=head3 add_interface($interface_name, $ip_address, $listen_port, $private_key)

Adds a (minimally configured) interface. If more attributes are needed, please set them using the C<set()> method.

B<Caveat:> No validation is performed on the values!

B<Parameters>

=over 1

=item *

C<$interface_name> A new interface name, must be unique.

=item *

C<$ip_address> A string describing the ip net(s) (e.g '10.0.0.0/24, fdc9:281f:04d7:9ee9::2/64')

=item *

C<$listen_port> The listen port for this interface.

=item *

C<$private_key> A private key for this interface

=back

B<Raises>

An exception if the interface name already exists.

B<Returns>

None

=cut
sub add_interface($self, $interface_name, $ip_address, $listen_port, $private_key) {
    if ($self->_is_valid_interface($interface_name)) {
        die "Interface `$interface_name` already exists"
    }
    my %interface = (
        'Address'    => $ip_address,
        'ListenPort' => $listen_port,
        'PrivateKey' => $private_key,
        'type'       => 'Interface',
        'order'      => [ 'Address', 'ListenPort', 'PrivateKey' ]
    );
    $self->{parsed_config}{$interface_name}{$interface_name} = \%interface;
    $self->{parsed_config}{$interface_name}{alias_map} = {};
    $self->{parsed_config}{$interface_name}{section_order} = [ $interface_name ];
    $self->{parsed_config}{$interface_name}{checksum} = 'none';
}

=head3 add_peer($interface, $name, $ip_address, $public_key [, $alias, $preshared_key])

Adds a peer to an exiting interface.

B<Caveat:> No validation is performed on the values!

B<Parameters>

=over 1

=item *

C<$interface> A valid interface.

=item *

C<$name> A name for this peer (wg-meta).

=item *

C<$ip_address> A string describing the ip-address(es) of this this peer.

=item *

C<$public_key> Public-key for this interface. This becomes the identifier of this peer.

=item *

C<[$preshared_key]> Optional argument defining the psk.

=item *

C<[$alias]> Optional argument defining an alias for this peer (wg-meta)

=back

B<Raises>

An exception if either the interface is invalid, the alias is already assigned or the public-key is
already present on an other peer.

B<Returns>

The private-key of the interface

=cut
sub add_peer($self, $interface, $name, $ip_address, $public_key, $alias = undef, $preshared_key = undef) {
    # generate new key pair if not defined
    if ($self->_is_valid_interface($interface)) {
        if ($self->_is_valid_identifier($interface, $public_key)) {
            die "An interface with this public-key already exists on `$interface`";
        }
        # generate peer config
        my %peer = (
            $self->{wg_meta_prefix} . 'Name' => $name,
            'PublicKey'                      => $public_key,
            'AllowedIPs'                     => $ip_address,
        );
        _add_to_hash_if_defined(\%peer, $self->{wg_meta_prefix} . 'Alias', $alias);
        _add_to_hash_if_defined(\%peer, 'PresharedKey', $preshared_key);

        # add to global config
        if (defined($alias)) {
            if (exists($self->{parsed_config}{$interface}{alias_map}{$alias})) {
                die "Alias `$alias` is already defined on interface `$interface`!";
            }
            $self->{parsed_config}{$interface}{alias_map}{$alias} = $public_key;
        }
        # add actual peer data
        $self->{parsed_config}{$interface}{$public_key} = \%peer;
        # add peer keys to order list
        $self->{parsed_config}{$interface}{$public_key}{order} = [ (keys %peer) ];
        # set type to to Peer
        $self->{parsed_config}{$interface}{$public_key}{type} = 'Peer';
        # add section to global section list
        push @{$self->{parsed_config}{$interface}{section_order}}, $public_key;

        return $self->{parsed_config}{$interface}{$interface}{PrivateKey};
    }
    else {
        die "Invalid interface `$interface`";
    }

}

# internal method to add to hash if value is defined
sub _add_to_hash_if_defined($ref_hash, $key, $value) {
    if (defined($value)) {
        $ref_hash->{$key} = $value;
    }
    return $ref_hash;
}

=head3 dump()

Simple dumper method to print contents of C<< $self->{parsed_config} >>.

=cut
sub dump($self) {
    print Dumper $self->{parsed_config};
}

1;