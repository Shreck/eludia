################################################################################

sub _sql_filters {

	my ($root, $filters) = @_;
		
	my $have_id_filter = 0;
	my $cnt_filters    = 0;
	my $where          = '';
	my $order;
	my $limit;
	my @params = ();

	foreach my $filter (@$filters) {
	
		if (ref $filter eq ARRAY and @$filter == 1 and $filter -> [0] =~ /^-?1\s/) {
		
			$filter = [LIMIT => [$filter -> [0]]];
			
		}

		ref $filter or $filter = [$filter, $_REQUEST {$filter}];

		my ($field, $values) = @$filter;

		if ($field eq 'ORDER') {
			$order = $values;
			next;
		}

		if ($field eq 'LIMIT') {
			$limit = $values;
			ref $limit or $limit = [$limit];
			next;
		}
		
		my $was_array = ref $values eq ARRAY or $values = [$values];

		my $first_value = $values -> [0];

		my $tied;

		if (ref $first_value eq SCALAR) {

			$tied = tied $$first_value;

		}

		unless ($tied) {

			next if $first_value eq '' or $first_value eq '0000-00-00';

		}
		
		if (($tied or $was_array) && $field =~ /^([a-z][a-z0-9_]*)$/) {
		
			$field .= ' IN';
		
		}

		$cnt_filters ++;

		$have_id_filter = 1 if $field eq 'id';

		$field =~ s{([a-z][a-z0-9_]*)}{$root.$1}gsm;

		if ($field =~ /\s+IN\s*$/sm) {

											# ['id_org IN' => sql_select_ids (...)] => "users.id_org IN (SELECT ...)"
											# ['id_org IN' => sql ('orgs(id)' => [[id_kind => 1]])] => "users.id_org IN (SELECT ...)"

			if ($tied) {							

				if (_sql_ok_subselects ()) {

					$where .= "\n  AND ($field ($tied->{sql}))";

					push @params, @{$tied -> {params}};

				}
				else {

					$where .= "\n  AND ($field ($$first_value))";

				}

			}
			else {								# ['id_org IN' => [0, undef, 1]] => "users.id_org IN (-1, 1)"

				$where .= "\n  AND ($field (-1";

				foreach (grep {/\d/} @$values) { $where .= ", $_"}

				$where .= "))";

			}

		}
		else {

			$field =~ /\w / or $field =~ /\=/ or $field .= ' = ';		# 'id_org'           --> 'id_org = '
			$field =~ /\?/  or $field .= ' ? '; 				# 'id_org LIKE '     --> 'id_org LIKE ?'
#			$field =~ s{LIKE\s+\%\?\%}{LIKE CONCAT('%', ?, '%')}gsm;
#			$field =~ s{LIKE\s+\?\%}{LIKE CONCAT(?, '%')}gsm;		# 'dt <+ 2008-09-30' --> 'dt < 2008-10-01'

			if ($field =~ s{\<\+}{\<}) {			
				my @ymd = split /\-/, $first_value;				
				$values -> [0] = dt_iso (Date::Calc::Add_Delta_Days (@ymd, 1));
			}
			
			my @tokens = split /(LIKE\s+\%?\?\%)/, $field;
			
			$where .= "\n AND (";
			
			foreach my $token (@tokens) {
			
				if ($token =~ /LIKE\s+(\%?)\?(\%)/) {

					$where .= ' LIKE ?';
					my $v = shift @$values;
					push @params, "$1$v$2";

				}
				else {
				
					$where .= $token;
					
					foreach (1 .. $token =~ y/?/?/) {
					
						push @params, shift @$values;
					
					}
				
				}
			
			}			

			$where .= ")";

#			$where .= "\n AND ($field)";
#			push @params, @$values;

		}


	}
	
	if (ref $limit eq ARRAY) {
	
		if (@$limit == 1 && $limit -> [0] =~ /^(.+?)\s*\,\s*(.+)$/) {
		
			$limit = [$1, $2];
		
		}
		
		if ($limit -> [0] =~ /^[a-z]\w*$/) {
		
			$limit -> [0] = 0 + $_REQUEST {$limit -> [0]};
		
		}
	
		if ($limit -> [-1] =~ s{\s+BY\s+(.*)}{}) {
		
			$order = $1;
		
		}
		
		if ($limit -> [-1] < 0) {
		
			$limit -> [-1] *= -1;
			
			$order .= ' DESC';
		
		}

	}
	
	return {
		have_id_filter => $have_id_filter,
		cnt_filters    => $cnt_filters,
		order          => $order,
		limit          => $limit,
		where          => $where,
		params         => \@params,
	};

}

################################################################################

sub _sql_unwrap_record {

	my ($record, $cols) = @_;

	foreach my $key (keys %$record) {
		
		if ($key =~ /^gfcrelf(\d+)$/) {
				
			my $def = $cols -> [$1];
				
			$record -> {$def -> [0]} -> {$def -> [1]} = delete $record -> {$key};
					
		}
		elsif ($key =~ /(\w+)\!(\w+)/) {

			my ($t, $f) = ($1, $2);

			$record -> {en_unplural ($t)} -> {$f} = delete $record -> {$key};

		}
					
	}

}

################################################################################

sub en_unplural {

	my ($s) = @_;

	if ($s =~ /status$/)                { return $s }
	if ($s =~ /goods$/)                 { return $s }
	if ($s =~ s{tives$}{tive})          { return $s }
	if ($s =~ s{ives$}{ife})            { return $s } # life, wife, knife
	if ($s =~ s{ves$}{f})               { return $s }
	if ($s =~ s{ies$}{y})               { return $s }
	if ($s =~ s{(\.)ice$}{$1ouse})      { return $s }
	if ($s =~ s{men$}{man})             { return $s }
	if ($s =~ s{eet(h?)$}{oot$1})       { return $s }
	if ($s =~ s{i$}{us})                { return $s }
	if ($s =~ s{a$}{um})                { return $s }
	if ($s =~ s{(o|ch|sh|ss|x)es$}{$1}) { return $s }
	$s =~ s{s$}{};
	return $s;

}

################################################################################

sub sql {

	if (ref $_[0] eq HASH) {
	
		my ($data, $root, @other) = @_;

		my ($records, $cnt, $portion) = sql ($root, @other);
		
		if ($root =~ /^\w+/) {
			$data -> {$&} = $records;
		}
		else {
			die "Invalid table reference: '$root'\n";
		}
		
		if ($portion) {
		
			$data -> {cnt}     = $cnt;
			$data -> {portion} = $portion;
		
		}
		
		return $data;
	
	}
	
	check___query ();
	
	my $_args = $preconf -> {core_debug_sql} ? [(), @_] : undef;

	my ($root_table, @other) = @_;
	
	my $sub;
	
	if (@other > 0 && ref $other [-1] eq CODE) {
	
		$sub = pop @other;
	
	}
	
	$root_table =~ /(\w+)(?:\((.*?)\))?/ or die "Invalid table definition: '$table'\n";

	my ($root, $root_columns) = ($1, $2);
	
	$root_columns ||= '*';
		
	my @root_columns = split /\s*\,\s*/, $root_columns;

	if ($root_columns [0] eq '*') {
	
		my $def = $DB_MODEL -> {tables} -> {$root};
		
		if ($def && $def -> {columns}) {

			@root_columns = keys %{$DB_MODEL -> {default_columns}};
			
			foreach my $k (keys %{$def -> {columns}}) {
			
				next if $def -> {columns} -> {$k} -> {TYPE_NAME} eq 'blob';
				
				push @root_columns, $k;
			
			}
		
		}

	}

	my $select  = "SELECT\n ";
	$select .= join ', ', map {"$root.$_\n "} @root_columns;

	my $from   = "\nFROM\n $root";
	my $where  = "\nWHERE 1=1 \n";
	my $order  = [$root . ($DB_MODEL -> {tables} -> {$root} -> {columns} -> {label} ? '.label' : '.id')];
	my $limit;
	my @join_params = ();
	my @params = ();

	if (@other == 0) {								# sql ('users')   --> sql ('users' => ['id'])
	
		@other = (['id']);
	
	}

	if (!ref $other [0]) {
	
		$other [0] = [[id => $other [0]]];					# sql (users => 1) --> sql ('users' => ['id' => 1])
	
	}
		
	my ($filters, @tables) = @other;
	
	my $sql_filters = _sql_filters ($root, $filters);
	
	$where .= $sql_filters -> {where};
	@params = @{$sql_filters -> {params}};
	$limit  = $sql_filters -> {limit};
	$order  = $sql_filters -> {order} if $sql_filters -> {order};
	my $have_id_filter = $sql_filters -> {have_id_filter};
	my $cnt_filters    = $sql_filters -> {cnt_filters};

	my $default_columns = '*';
	
	unless ($have_id_filter) {
		
		$default_columns = 'id, label, fake';

		$where .= $_REQUEST {fake} =~ /\,/ ? "\n AND $root.fake IN ($_REQUEST{fake})" : "\n AND $root.fake = " . ($_REQUEST {fake} || 0);

	}	
		
	foreach my $table (@tables) {
	
		my $filters = undef;
	
		if (ref $table eq ARRAY) { 
			$filters = $table -> [1] || [];
			$table   = $table -> [0];
		}
		
		my $on = '';

		if ($table =~ /\s+ON\s+/) {

			$table = $`;
			$on    = $';

		}

		my $alias = '';
		
		if ($table =~ /\s+AS\s+(\w+)\s*$/) {

			$table = $`;
			$alias = $1;

		}
		
		$table =~ s{\s}{}gsm;

		$table =~ /(\-?)(\w+)(?:\((.*?)\))?/ or die "Invalid table definition: '$table'\n";

		my ($minus, $name, $columns) = ($1, $2, $3);

		$alias ||= $name;
		
		if ($on && $on !~ /\s/) {
		
			$on = "$on = $alias.id";
		
		}

		$table = {
		
			src     => $table,
			name    => $name,
			columns => $columns,
			single  => en_unplural ($alias),
			alias   => $alias,
			on      => $on,
			filters => $filters,
			join    => $minus ? 'INNER JOIN' : 'LEFT JOIN',
			
		};
		
		$table -> {single} =~ s{ie$}{y};

	}	
	
	my @cols = ();
	my $cols_cnt = 0;	
			
	foreach my $table (@tables) {

		my $found = 0;
		
		if ($table -> {on}) {
		
			$from .= "\n $table->{join} $table->{name}";
			$from .= " AS $table->{alias}" if $table -> {name} ne $table -> {alias};
			$from .= " ON ($table->{on})";
				
			$found = 1;
		
		}
		
		if (!$found && $table -> {filters}) {
		
			my $definition = $DB_MODEL -> {tables} -> {$table -> {name}};

			my $referring_columns = $definition -> {columns};
			
			my @t = ({name => $root, single => en_unplural ($root)});
			
			foreach my $t (@tables) {
			
				last if $t -> {alias} eq $table -> {alias};
				
				push @t, $t;
			
			}

			foreach my $t (reverse @t) {
			
				my $referring_field_name = 'id_' . $t -> {single};
				
				my $column = $referring_columns -> {$referring_field_name};
			
				unless ($column) {

					foreach my $k (keys %$referring_columns) {

						my $c = $referring_columns -> {$k};

						$c -> {ref} eq $t -> {name} or next;

						$column = $c;
						$referring_field_name = $k;

						last;

					}

				}

				$column or next;

				my $sql_filters = _sql_filters ($table -> {alias}, $table -> {filters});

				$from .= "\n $table->{join} $table->{name}";
				$from .= " AS $table->{alias}" if $table -> {name} ne $table -> {alias};
				$from .= " ON ($table->{alias}.$referring_field_name = $t->{name}.id $sql_filters->{where})";
				
				push @join_params, @{$sql_filters -> {params}};

				$found = 1;

				last;

			}
					
		}
		
		if (!$found) {
		
			my $referring_field_name = 'id_' . $table -> {single};

			foreach my $t ({name => $root}, @tables) {

				my $referring_table = $DB_MODEL -> {tables} -> {$t -> {name}};

				my $column = $referring_table -> {columns} -> {$referring_field_name};

				unless ($column) {

					my $referring_columns = $referring_table -> {columns};

					foreach my $k (keys %$referring_columns) {

						my $c = $referring_columns -> {$k};

						$c -> {ref} eq $table -> {name} or next;

						$column = $c;
						$referring_field_name = $k;

						last;

					}

				}

				$column or next;

				$from .= "\n $table->{join} $table->{name}";
				$from .= " AS $table->{alias}" if $table -> {name} ne $table -> {alias};
				
				$t -> {alias} ||= $t -> {name};

				if ($table -> {filters}) {
					my $sql_filters = _sql_filters ($table -> {alias}, $table -> {filters});
					$from .= " ON ($t->{alias}.$referring_field_name = $table->{alias}.id $sql_filters->{where})";
					push @join_params, @{$sql_filters -> {params}};
				}
				else {
					$from .= " ON $t->{alias}.$referring_field_name = $table->{alias}.id";
				}

				$found = 1;

				last;

			}		

		}		

		$found or die "Referrer for $table->{alias} not found\n";

		$table -> {columns} ||= $default_columns;
		
		my @columns = ();
		
		my $def = $DB_MODEL -> {tables} -> {$table -> {name}} -> {columns};
		
		if ($table -> {columns} eq '*' and $def) {
		
			@columns = ('id', 'fake', keys %$def);
		
		}
		else {
		
			@columns = split /\s*\,\s*/, $table -> {columns};
		
		}
		
		foreach my $column (@columns) {
		
			next if $def -> {$column} -> {TYPE_NAME} eq 'blob';
		
			$cols [$cols_cnt] = [en_unplural ($table -> {alias}), $column];
		
			$select .= "\n, $table->{alias}.$column AS gfcrelf$cols_cnt",

			$cols_cnt ++;
		
		}
			
	}
	
	my $sql = $select . $from . $where;
	
	@params = (@join_params, @params);

	my $is_ids = (@root_columns == 1 && $root_columns [0] ne '*') ? 1 : 0;
	
	my $is_first = $limit && @$limit == 1 && $limit -> [0] == 1;
	
	!$is_ids or $cnt_filters or $is_first or return undef;
	
	if ((!$have_id_filter && !$is_ids) || $is_first) {
	
		$order = order ($order)  if $order !~ /\W/;
		$order = order (@$order) if ref $order eq ARRAY;
		$order =~ s{(?<!\.)\b([a-z][a-z0-9_]*)\b(?!\.)}{${root}.$1}gsm;
		$sql .= "\nORDER BY\n $order";

	}

	my @result;
	my $records;
	
	if ($preconf -> {core_debug_sql}) {
	
		warn Dumper ({args => $_args, sql => $sql, params => \@params});
	
	}
	
	if ($have_id_filter || $is_first) {
	
		return sql_select_scalar ($sql, @params) if $is_ids;

		@result = (sql_select_hash ($sql, @params));

		$records = [$result [0]];

	}
	elsif ($sub) {
	
		return sql_select_loop (
			
			$sql, 
			
			sub {
			
				_sql_unwrap_record ($i, \@cols);
				
				&$sub ($i);
				
			}, 
			
			@params
			
		);
	
	}
	else {
	
		if ($limit) {
		
			$sql .= "\nLIMIT\n " . (join ', ', @$limit);
			
			@result = (sql_select_all_cnt ($sql, @params), $limit -> [1]);
	
			$records = $result [0];
	
		}
		else {

			if ($is_ids) {
							
				$sql =~ s{^SELECT}{SELECT DISTINCT};

				my $ids;
				
				my $tied = tie $ids, 'Eludia::Tie::IdsList', {

					sql 			=> $sql,

					_REQUEST 		=> \%_REQUEST,

					package 		=> __PACKAGE__,

					params 			=> \@params,

					db 			=> $db,
			
					sql_translator_ref	=> get_sql_translator_ref(),

				};

				return \$ids;

			}
			else {

				@result = (sql_select_all ($sql, @params));

				$records = $result [0];

			}

		}
	
	}	

	foreach my $record (@$records) {
	
		_sql_unwrap_record ($record, \@cols);
	
	}
	
	return wantarray ? @result : $result [0];

}

1;