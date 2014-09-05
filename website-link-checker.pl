#!/usr/bin/env perl

=pod

	AUTHOR: nazuke.hondou@googlemail.com
	UPDATED: 20140905

	ABOUT:

		This Perl program is a simple website link checker.
		This program should work on UNIX/Linux, Mac OS X and Windows systems.
		For Windows, this has been known to work under Strawberry Perl.

		See the accompanying README.TXT file for more information.

=cut

##########################################################################################

package Nazuke::LinkChecker;

$Nazuke::LinkChecker::VERSION = '0.01';
use Modern::Perl qw( 2010 );
use Carp qw( cluck );
use Getopt::Long;
use Data::Dumper;
use CSS;
use Encode;
use Excel::Writer::XLSX;
use File::Util;
use HTML::Parser;
use HTTP::Cookies;
use HTTP::Date qw( time2str str2time );
use MIME::Base64;
use MIME::Entity;
use Net::SMTP;
use Net::SMTP::SSL;
use URI::Escape;
use URI;
use WWW::Mechanize;
1;

$SIG{'INT'}  = sub { exit(0); };
$SIG{'TERM'} = sub { exit(0); };

my $scan  = Nazuke::LinkChecker->new();
my $count = 0;

$scan->logger( 'STARTED...' );

URL: foreach my $url ( @{$scan->{'config'}->{'url'}} ) {
	$scan->logger( qq(URL: "$url") );
	$scan->{'seed'}->{'URI'} = URI->new( $url );
	$scan->recurse( url => $url, referer => '' );
}

$scan->logger( qq(FAULT(S) FOUND:) );

$scan->log_depth(1);

foreach my $key ( keys( %{$scan->{'faults'}} ) ) {
	$scan->logger( qq(FAULT: "$key") );
	$scan->logger( qq(STATUS: "$scan->{'faults'}->{$key}->{'status'}") );
	$scan->log_depth(1);
	foreach my $referer ( keys( %{$scan->{'faults'}->{$key}->{'referer'}} ) ) {
		$scan->logger( qq(REFERRER: "$referer") );
	}
	$scan->log_depth(-1);
	$count++;
}

$scan->logger( qq($count FAULT(S)) );

my $excel = $scan->generate_excel_report();

my $attachments = [
	{
		data     => $excel,
		filename => 'Link-Checker-Report.xlsx',
		mimetype => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
	}
];

$scan->send_report( $attachments );

$scan->logger( qq(DONE.) );

exit(0);

##########################################################################################

sub Nazuke::LinkChecker::new {
	my $package = shift;
	my $self    = {};
	my $time    = time();

	bless( $self, $package );

	$self->status( 'INITIALIZING...' );

	$self->{'SMTP'} = {
		'MAIL_DOMAIN'   => '', # Domain of the email user.
		'HOST'     => '', # Address of SMTP Server.
		'PORT'     => '', # Port to connect to on SMTP Server.
		'FROM'     => '', # Email address for FROM field.
		'USER'     => '', # Email address of user for SMTP Server.
		'ENCRYPT'  => 0,  # true/false to use SSL.
		'USERNAME' => '', # SMTP Username.
		'PASSWORD' => ''  # SMTP Password.
	};

	$self->{'config_file'}     = undef;
	$self->{'config'}          = {};

	$self->{'logfile'}         = undef;
	$self->{'log_depth'}       = 0;

	$self->{'domains'}         = {};
	$self->{'config'}->{'url'} = [];

	$self->{'allow'}           = {};
	$self->{'disallow'}        = {};

	$self->{'http_status'}     = {};
	$self->{'history'}         = {};
	$self->{'faults'}          = {};
	$self->{'recipients'}      = [];
	$self->{'mech'}            = WWW::Mechanize->new( agent => "website-link-checker v${Nazuke::LinkChecker::VERSION}" );

	GetOptions(
		'config=s' => \$self->{'config_file'}
	);

	$self->load_config();

	if( $self->{'config'}->{'proxy'} ) {
		$self->status( 'Using Proxy: ' . $self->{'config'}->{'proxy'} );
		$self->{'mech'}->proxy( 'http', $self->{'config'}->{'proxy'} );
	}

	return( $self );
}

##########################################################################################

sub Nazuke::LinkChecker::load_config {
	my $self         = shift;
	my %args         = @_;
	my $cfg_path     = $self->{'config_file'};
	my %cookie_name  = ();
	my %cookie_value = ();
	$self->log_depth(1);
	if( open( CONFIG, $cfg_path ) ) {
		$self->status( qq(Reading Config: "$cfg_path") );
		$self->log_depth(1);
		while( my $line = <CONFIG> ) {
			chomp( $line );
			if( $line ) {
				my ( $key, $value ) = ( $line =~ m/^\s*([^=]+)=(.+)\s*$/ );
				if( $key ) {

					if( $key =~ m/^url$/i ) {
						my $URI = URI->new( $value );
						push( @{$self->{'config'}->{'url'}}, $value );
						$self->{'domains'}->{$URI->host()} = $URI->host();

					} elsif( $key =~ m/^logfile$/i ) {
						$self->{'logfile'} = $value;

					} elsif( $key =~ m/^allow$/i ) {
						$self->{'allow'}->{$value} = $value;
						$self->status( qq(Allow Pattern: "$value") );

					} elsif( $key =~ m/^disallow$/i ) {
						$self->{'disallow'}->{$value} = $value;
						$self->status( qq(Disallow Pattern: "$value") );

					} elsif( $key =~ m/^cookie_name([0-9]+)$/i ) {
						$cookie_name{$1} = $value;

					} elsif( $key =~ m/^cookie_value([0-9]+)$/i ) {
						$cookie_value{$1} = $value;

					} elsif( $key =~ m/^http_status$/i ) {
						$self->{'http_status'}->{$value} = $value;

					} elsif( $key =~ m/^recipient$/i ) {
						push( @{$self->{'recipients'}}, $value );

					} elsif( $key =~ m/^mail-domain$/i ) {
						$self->{'SMTP'}->{'MAIL_DOMAIN'} = $value;

					} elsif( $key =~ m/^smtp-host$/i ) {
						$self->{'SMTP'}->{'HOST'} = $value;

					} elsif( $key =~ m/^smtp-port$/i ) {
						$self->{'SMTP'}->{'PORT'} = int( $value );

					} elsif( $key =~ m/^smtp-from$/i ) {
						$self->{'SMTP'}->{'FROM'} = $value;

					} elsif( $key =~ m/^smtp-user$/i ) {
						$self->{'SMTP'}->{'USER'} = $value;

					} elsif( $key =~ m/^smtp-username$/i ) {
						$self->{'SMTP'}->{'USERNAME'} = $value;

					} elsif( $key =~ m/^smtp-password$/i ) {
						$self->{'SMTP'}->{'PASSWORD'} = $value;

					} elsif( $key =~ m/^encrypt$/i ) {
						if( lc( $value ) eq 'true' ) {
							$self->{'SMTP'}->{'ENCRYPT'} = 1;
						}

					} else {
						$self->{'config'}->{$key} = $value;
					}
				}
			}
		}
		$self->log_depth(-1);
		close( CONFIG );
		$self->log_depth(1);
		foreach my $key ( keys( %cookie_name ) ) {
			$self->status( "Loaded Cookie: $cookie_name{$key} => $cookie_value{$key}" );
			$self->{'cookies'}->{$cookie_name{$key}} = $cookie_value{$key};
		}
		$self->log_depth(-1);
	} else {
		$self->status( 'ERROR: Cannot open config: ' . $cfg_path );
		die( "ERROR: Cannot open config: $cfg_path\n" );
	}
	$self->log_depth(-1);
	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::get_cookie_jar {
	my $self         = shift;
	my $URI         = shift;
	my %args        = @_;
	my $cookie_path = $0;
	$cookie_path    =~ s:\\:/:g;
	$cookie_path    =~ s:/[^/]+$:/cookies.txt:;
	my $cookie_jar = HTTP::Cookies->new(
		file     => $cookie_path,
		autosave => 1,
	);
	foreach my $key ( keys( %{$self->{'cookies'}} ) ) {
		$cookie_jar->set_cookie(
			'1.0',
			$key,
			$self->{'cookies'}->{$key},
			'/',
			$URI->host(),
			80,
			'/',
			0,
			60 * 60 * 24 * 365,
			0,
			()
		);
	}
	return( $cookie_jar );
}

##########################################################################################

sub Nazuke::LinkChecker::recurse {
	my $self    = shift;
	my %args    = @_;
	my $url     = $args{'url'};
	my $referer = $args{'referer'};

	my $URI     = URI->new( $url );
	my $mech    = $self->{'mech'};

	$self->log_depth(1);

	if( exists( $self->{'history'}->{$url} ) ) {
		$self->check_faulty( url => $url, referer => $referer );
		$self->log_depth(-1);
		return(1);
	}

	if( $URI->scheme() !~ m/^(http|https)$/i ) {
		$self->log_depth(-1);
		return(1);
	}

	if( $URI->fragment() ) {
		$self->log_depth(-1);
		return(1);
	}

	if( $self->allow_disallow_url( url => $url ) ) {
		$self->logger( qq(Allowing: "$url") );
	} else {
		$self->logger( qq(Disallowing: "$url") );
		$self->log_depth(-1);
		return(1);
	}

	if( $self->{'domains'}->{$URI->host()} ) {

		$self->logger( qq(Fetching: "$url") );

		$self->log_depth(1);

		eval {
			$mech->head( $url );
		};

		if( $@ ) {

			$self->logger( $@ );
			$self->logger( $mech->status() );

			$self->update_fault(
				url     => $url,
				status  => $mech->status(),
				referer => $referer,
				comment => ''
			);

			$self->check_faulty( url => $url, referer => $referer );
			$self->{'history'}->{$url} = 1;
			$self->logger( qq(ABNORMAL HTTP_STATUS) );

		} else {

			if( $mech->success() ) {

				$self->check_faulty( url => $url, referer => $referer );
				$self->{'history'}->{$url} = 1;

				if( exists( $self->{'http_status'}->{$mech->status()} ) ) {

					$self->logger( qq(OK) );

					if( $mech->is_html() ) {

						$mech->get( $url );
						$self->logger( qq(Is HTML: "$url") );

						my @links        = $mech->links();
						my @images       = $mech->images();
						my @supplemental = $self->supplemental();

						LINKS: foreach my $link ( @links ) {
							my $sub_url = $link->url_abs();
							if( $link->URI()->fragment() ) {
								next LINKS;
							}
							$sub_url =~ s:^(.+)#$:$1:;
							if( exists( $self->{'history'}->{$sub_url} ) ) {
								next LINKS;
							} else {
								$self->logger( qq(Recursing Link: "$sub_url") );
								$self->recurse( url => $sub_url, referer => $url );
								$self->check_faulty( url => $sub_url, referer => $url );
								$self->{'history'}->{$sub_url} = 1;
							}
						}

						IMAGES: foreach my $image ( @images ) {
							my $sub_url = $image->url_abs();
							if( $image->URI()->fragment() ) {
								next IMAGES;
							}
							$sub_url =~ s:^(.+)#$:$1:;
							if( exists( $self->{'history'}->{$sub_url} ) ) {
								next IMAGES;
							} else {
								$self->logger( qq(Image: "$sub_url") );
								$self->check_special_link( url => $sub_url, referer => $url );
								$self->check_faulty( url => $sub_url, referer => $url );
								$self->{'history'}->{$sub_url} = 1;
							}
						}

						SUPPLEMENTAL: foreach my $suppl ( @supplemental ) {
							my $sub_url = $suppl->url_abs();
							if( $suppl->URI()->fragment() ) {
								next SUPPLEMENTAL;
							}
							$sub_url =~ s:^(.+)#$:$1:;
							if( exists( $self->{'history'}->{$sub_url} ) ) {
								next SUPPLEMENTAL;
							} else {
								$self->logger( qq(Supplemental: "$sub_url") );
								$self->check_special_link( url => $sub_url, referer => $url );
								$self->check_faulty( url => $sub_url, referer => $url );
								$self->{'history'}->{$sub_url} = 1;
							}
						}

					} elsif( lc( $mech->ct() ) eq 'text/css' ){

						$mech->get( $url );
						$self->logger( qq(CSS: "$url") );
						my @links = $self->css( url => $url, referer => $referer );

						CSS: foreach my $link ( @links ) {
							my $sub_url = $link->url_abs();
							if( $link->URI()->fragment() ) {
								next CSS;
							}
							$sub_url =~ s:^(.+)#$:$1:;
							if( exists( $self->{'history'}->{$sub_url} ) ) {
								next CSS;
							} else {
								$self->logger( qq(CSS Link: "$sub_url") );
								$self->check_special_link( url => $sub_url, referer => $referer );
								$self->check_faulty( url => $sub_url, referer => $referer );
								$self->{'history'}->{$sub_url} = 1;
							}
						}

					} else {
						$self->logger( qq(Not HTML: "$url") );
						$self->check_special_link( url => $url, referer => $url );
					}

				} else {

					$self->logger( $mech->status() );

					$self->update_fault(
						url     => $url,
						status  => $mech->status(),
						referer => $referer,
						comment => ''
					);

					$self->logger( qq(ABNORMAL HTTP_STATUS) );

				}

			} else {

				$self->logger( qq(ERROR: "$url") );
				$self->check_faulty( url => $url, referer => $referer );
				$self->{'history'}->{$url} = 1;

				$self->update_fault(
					url     => $url,
					status  => $mech->status(),
					referer => $referer,
					comment => ''
				);

			}

		}

		$self->log_depth(-1);

	} else {

		$self->check_faulty( url => $url, referer => $referer );
		$self->{'history'}->{$url} = 1;
		$self->logger( qq(Not in Domain: "$url") );
		$self->check_special_link( url => $url, referer => $referer );

	}


	$self->log_depth(-1);

	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::check_special_link {
	my $self    = shift;
	my %args    = @_;
	my $url     = $args{'url'};
	my $referer = $args{'referer'};

	my $URI     = URI->new( $url );
	my $mech    = $self->{'mech'};

	if( exists( $self->{'history'}->{$url} ) ) {
		$self->check_faulty( url => $url, referer => $referer );
		return(1);
	}

	if( $self->allow_disallow_url( url => $url ) ) {
		$self->logger( qq(Allowing: "$url") );
	} else {
		$self->logger( qq(Disallowing: "$url") );
		return(1);
	}

	eval {
		$mech->head( $url );
	};

	if( $@ ) {

		$self->logger( $@ );
		$self->logger( $mech->status() );

		$self->update_fault(
			url     => $url,
			status  => $mech->status(),
			referer => $referer,
			comment => ''
		);

		$self->check_faulty( url => $url, referer => $referer );
		$self->{'history'}->{$url} = 1;
		$self->logger( qq(ABNORMAL HTTP_STATUS) );

	} else {

		if( $mech->success() ) {

			$self->check_faulty( url => $url, referer => $referer );
			$self->{'history'}->{$url} = 1;

		} else {

			$self->update_fault(
				url     => $url,
				status  => $mech->status(),
				referer => $referer,
				comment => ''
			);

			$self->check_faulty( url => $url, referer => $referer );
			$self->{'history'}->{$url} = 1;
		}

	}

	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::allow_disallow_url {
	my $self          = shift;
	my %args          = @_;
	my $url           = $args{'url'};
	my $allow         = 1;
	my $url_unescaped = URI::Escape::uri_unescape( $url );
	DISALLOW: foreach my $key ( keys( %{$self->{'disallow'}} ) ) {
		if( $url_unescaped =~ m/$key/ ) {
			$self->{'history'}->{$url} = 1;
			$allow = 0;
			last DISALLOW;
		}
	}
	ALLOW: foreach my $key ( keys( %{$self->{'allow'}} ) ) {
		if( $url_unescaped =~ m/$key/ ) {
			$self->{'history'}->{$url} = 1;
			$allow = 1;
			last ALLOW;
		}
	}
	return( $allow );
}

##########################################################################################

sub Nazuke::LinkChecker::supplemental {
	my $self    = shift;
	my %args    = @_;
	my $mech    = $self->{'mech'};
	my $html    = $mech->response()->decoded_content();
	my @links   = ();

	my $t_start = sub {
		my $tagname = shift;
		my $attr    = shift;
		if( lc( $tagname ) eq 'script' ) {
			foreach my $name ( keys( %{$attr} ) ) {
				if( lc( $name ) eq 'src' ) {
					my $link = WWW::Mechanize::Link->new( {
						url  => $attr->{$name},
						base => $self->{'mech'}->uri()
					} );
					push( @links, $link );
				}
			}
		}
		return(1);
	};

	my $Parser = HTML::Parser->new(
		api_version     => 3,
		start_h         => [ $t_start, "tagname, attr" ],
		marked_sections => 1,
	);

	$Parser->parse( $html );
	$Parser->eof();
	undef( $Parser );

	return( @links );
}

##########################################################################################

sub Nazuke::LinkChecker::css {
	my $self    = shift;
	my %args    = @_;
	my $url     = $args{'url'};
	my $referer = $args{'referer'};
	my $mech    = $self->{'mech'};
  my $CSS     = CSS->new( { 'parser' => 'CSS::Parse::Lite' } );
	my @links   = ();
  eval {
		$CSS->read_string( $mech->response()->decoded_content() );
	};
	if( $@ ) {
		$self->logger( qq(CSS Fault) );
		$self->update_fault(
			url     => $url,
			status  => $mech->status(),
			referer => $referer,
			comment => 'CSS Fault found. Use a CSS validator to identify nature of fault.'
		);
	} else {
		foreach my $style ( @{$CSS->{'styles'}} ) {
			foreach my $prop ( $style->properties() ) {
				if( $prop =~ m/url\(["']?[^()"']+["']?\)\s?/ ) {
					while( $prop =~ m/url\(["']?([^()"']+)["']?\)\s?/gis ) {
						my $uri = $1;
						if( $uri ) {
							$self->logger( qq(CSS URI: "$uri") );
							my $link = WWW::Mechanize::Link->new( {
								url  => $uri,
								base => $url
							} );
							push( @links, $link );
						}
					}
				}
			}
		}
		$CSS->purge();
		undef( $CSS );
	}
	return( @links );
}

##########################################################################################

sub Nazuke::LinkChecker::check_faulty {
	my $self    = shift;
	my %args    = @_;
	my $url     = $args{'url'};
	my $referer = $args{'referer'} || '';
	if( $self->{'faults'}->{$url} ) {
		$self->update_fault(
			url     => $url,
			status  => $self->{'faults'}->{$url}->{'status'},
			referer => $referer,
			comment => $self->{'faults'}->{$url}->{'comment'}
		);
	}
	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::update_fault {
	my $self    = shift;
	my %args    = @_;
	my $url     = $args{'url'};
	my $status  = $args{'status'} || '';
	my $referer = $args{'referer'} || '';
	my $comment = $args{'comment'} || '';
	if( $self->{'faults'}->{$url} ) {
		if( $status ) {
			$self->{'faults'}->{$url}->{'status'} = $status;
		}
		if( $referer ) {
			$self->{'faults'}->{$url}->{'referer'}->{$referer} = $referer;
		}
		if( $comment ) {
			$self->{'faults'}->{$url}->{'comment'} = $comment;
		}
	} else {
		$self->{'faults'}->{$url} = {
			status  => $status,
			referer => { $referer => $referer },
			comment => $comment
		};
	}
	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::generate_excel_report {
	my $self = shift;
	my $fh   = undef;

	open( $fh, '>', \my $data );

	my $workbook   = Excel::Writer::XLSX->new( $fh );

	my $fmt_header = $workbook->add_format(
		bold     => 1,
		color    => 'white',
		bg_color => 'black'
	);

	my $worksheet = $workbook->add_worksheet();
	my $column_names = [];
	my $row_num   = 0;
	my $col_num   = 0;

	foreach my $name ( 'status', 'url', 'referrer', 'comment' ) {
		$worksheet->write_string( $row_num, $col_num, $name, $fmt_header );
		push( @{$column_names}, { header => $name } );
		$col_num++;
	}

	$row_num++;

	foreach my $url ( keys( %{$self->{'faults'}} ) ) {

		foreach my $referer ( keys( %{$self->{'faults'}->{$url}->{'referer'}} ) ) {

			$col_num = 0;

			$worksheet->write_number( $row_num, $col_num, $self->{'faults'}->{$url}->{'status'} );
			$worksheet->set_column( $row_num, $col_num, 10 );
			$col_num++;

			$worksheet->write_url( $row_num, $col_num, $url );
			$worksheet->set_column( $row_num, $col_num, 50 );
			$col_num++;

			$worksheet->write_url( $row_num, $col_num, $referer );
			$worksheet->set_column( $row_num, $col_num, 50 );
			$col_num++;

			$worksheet->write_string( $row_num, $col_num, $self->{'faults'}->{$url}->{'comment'} );
			$worksheet->set_column( $row_num, $col_num, 60 );

			$row_num++;

		}

	}

	$worksheet->add_table(
		0,
		0,
		$row_num - 1,
		3,
		{
			header_row => 1,
			columns    => $column_names
		}
	);

	$workbook->close();

	close( $fh );

	return( $data );
}

##########################################################################################

sub Nazuke::LinkChecker::send_report {
	my $self        = shift;
	my $attachments = shift;
	my $message     = qq(This is an automatically generated message.\n\nSee attached Excel sheet for a simple list of anomalous URLs detailed in the activity log below.\n\nFor more information about HTTP Status Codes: http://en.wikipedia.org/wiki/List_of_HTTP_status_codes\n\n);
	if( open( SENDLOGFILE, $self->{'logfile'} ) ) {
		$message = join(
			'',
			$message,
			<SENDLOGFILE>
		);
		foreach my $recipient( @{$self->{'recipients'}} ) {
			$self->sendmail(
				to          => $recipient,
				subject     => qq(Website-Link-Checker Report),
				mimetype    => 'text/plain',
				message     => $message,
				attachments => $attachments
			);
		}
	} else {
		die( qq(Cannot Open "$self->{'logfile'}") );
	}
	return(1);
}

##########################################################################################

=pod

	EXAMPLE:

	$self->sendmail(
		from        => 'some-user@some-domain.com',
		recipient   => $recipient,
		subject     => qq(A Report),
		message     => $message,
		attachments => \@attachments
	);

=cut

sub Nazuke::LinkChecker::sendmail {
	my $self          = shift;
	my %args          = @_;
	my $to            = $args{'to'} || die("No TO Field Specified");
	my $cc            = $args{'cc'} || '';
	my $subject       = $args{'subject'} || die("No SUBJECT Field Specified");
	my $mimetype      = $args{'mimetype'} || die("No MIMETYPE Field Specified");
	my $message       = $args{'message'} || die("No MESSAGE Field Specified");
	my $attachments   = $args{'attachments'} || [];

	my $smtp          = undef;
	my $smtp_encrypt  = $self->{'SMTP'}->{'ENCRYPT'} || 0;
	my $smtp_username = $self->{'SMTP'}->{'USERNAME'} || undef;
	my $smtp_password = $self->{'SMTP'}->{'PASSWORD'} || undef;

	if( $smtp_encrypt ) {
		$smtp = Net::SMTP::SSL->new(
			$self->{'SMTP'}->{'HOST'},
			Port  => $self->{'SMTP'}->{'PORT'},
			Hello => $self->{'SMTP'}->{'MAIL_DOMAIN'},
			Debug => 0
		);
		if( defined( $smtp ) ) {
			if( $smtp_username && $smtp_password ) {
				$self->logger( qq(Authenticating...), 3 );
				$smtp->auth( $smtp_username, $smtp_password );
			} else {
				$self->logger( qq(Skipping Authentication), 3 );
			}
		}
	} else {
		$smtp = Net::SMTP->new(
			$self->{'SMTP'}->{'HOST'},
			Hello => $self->{'SMTP'}->{'MAIL_DOMAIN'},
			Debug => 0
		);
	}

	if( defined( $smtp ) ) {
		$smtp->mail( $self->{'SMTP'}->{'USER'} );
		$smtp->to( $to );

		if( $cc ) {
			$smtp->cc( $cc );
		}

		$smtp->data();

		$smtp->datasend(
			$self->build_multipart(
				to          => $to,
				subject     => $subject,
				mimetype    => $mimetype,
				message     => $message,
				attachments => $attachments
			)
		);

		$smtp->dataend();
		$smtp->quit();

	} else {
		return( undef );
	}

	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::build_multipart {
	my $self        = shift;

	my %args        = @_;

	my $to          = $args{'to'} || die("No TO Field Specified");
	my $subject     = $args{'subject'} || die("No SUBJECT Field Specified");
	my $mimetype    = $args{'mimetype'} || die("No MIMETYPE Field Specified");
	my $message     = $args{'message'} || die("No MESSAGE Field Specified");
	my $attachments = $args{'attachments'} || [];

	my $mime        = MIME::Entity->build(
		'Type'     => "multipart/mixed",
		'From'     => $self->{'SMTP'}->{'FROM'},
		'Reply-To' => $self->{'SMTP'}->{'FROM'},
		'To'       => $to,
		'Subject'  => $subject,
		'Data'     => [ $message ]
	);

	$mime->attach(
		Data     => $message,
		Type     => $mimetype,
		Encoding => 'base64'
	);

	foreach my $item ( @{$attachments} ) {
		$mime->attach(
			Filename => $item->{'filename'},
			Data     => $item->{'data'},
			Type     => $item->{'mimetype'},
			Encoding => 'base64'
		);
	}

	return( $mime->stringify() );
}

##########################################################################################

sub Nazuke::LinkChecker::log_depth {
	my $self  = shift;
	my $value = shift || 0;
	if( $value != 0 ) {
		$self->{'log_depth'} = $self->{'log_depth'} + $value;
	}
	return( $self->{'log_depth'} );
}

##########################################################################################

sub Nazuke::LinkChecker::logger {
	my $self    = shift;
	my $message = shift;
	my $logline = gmtime() .  ( '  ' x $self->log_depth() ) . ' ' .  $message . "\n";
	eval {
		if( open( LOGFILE, ">>" . $self->{'logfile'} ) ) {
			print( $logline );
			print( LOGFILE $logline );
			close( LOGFILE );
		} else {
			die( qq(Cannot Open "$self->{'logfile'}") );
		}
	};
	if( $@ ) {
		cluck( $@ );
		die;
	}
	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::status {
	my $self    = shift;
	my $message = shift;
	my $logline = gmtime() .  ( '  ' x $self->log_depth() ) . ' ' .  $message . "\n";
	print( $logline );
	return(1);
}

##########################################################################################

sub Nazuke::LinkChecker::DESTROY {
	my $self = shift;
	my $path = $self->{'logfile'};
	if( unlink( $path ) ) {
		print( STDERR qq(Unlinked Log File: "$path"\n) );
	} else {
		print( STDERR qq(Cannot Unlink Log File: "$path"\n) );
	}
}

##########################################################################################
