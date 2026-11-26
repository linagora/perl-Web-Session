package Apache::Session::Browseable::MariaDB;

use strict;
use Apache::Session::Browseable::MariaDBJSON;

our $VERSION = '1.4.0';
our @ISA     = qw(Apache::Session::Browseable::MariaDBJSON);

# populate() is also called as a function
*populate = \&Apache::Session::Browseable::MariaDBJSON::populate;

1;
__END__

=head1 NAME

Apache::Session::Browseable::MariaDB - Alias of
L<Apache::Session::Browseable::MariaDBJSON>

=head1 SYNOPSIS

  use Apache::Session::Browseable::MariaDB;

  my $args = {
       DataSource => 'dbi:MariaDB:sessions',
       UserName   => $db_user,
       Password   => $db_pass,
       Commit     => 1,
  };

  tie %session, 'Apache::Session::Browseable::MariaDB', $id, $args;

=head1 DESCRIPTION

This module is an alias of L<Apache::Session::Browseable::MariaDBJSON>:
sessions are stored as JSON in a C<json> column, and indexes are built on
generated columns. See L<Apache::Session::Browseable::MariaDBJSON> for the
table, the indexes and the available options.

=head1 SEE ALSO

L<Apache::Session::Browseable::MariaDBJSON>, L<Apache::Session::Browseable>

=head1 COPYRIGHT AND LICENSE

=encoding utf8

=over

=item 2009-2025 by Xavier Guimard

=item 2013-2025 by Clément Oudot

=item 2019-2025 by Maxime Besson

=item 2013-2025 by Worteks

=item 2023-2025 by Linagora

=back

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.

=cut
