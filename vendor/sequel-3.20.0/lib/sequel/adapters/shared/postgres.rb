module Sequel
  Dataset::NON_SQL_OPTIONS << :disable_insert_returning

  # Top level module for holding all PostgreSQL-related modules and classes
  # for Sequel.  There are a few module level accessors that are added via
  # metaprogramming.  These are:
  # * client_min_messages (only available when using the native adapter) -
  #   Change the minimum level of messages that PostgreSQL will send to the
  #   the client.  The PostgreSQL default is NOTICE, the Sequel default is
  #   WARNING.  Set to nil to not change the server default.
  # * force_standard_strings - Set to false to not force the use of
  #   standard strings
  # * use_iso_date_format (only available when using the native adapter) -
  #   Set to false to not change the date format to
  #   ISO.  This disables one of Sequel's optimizations.
  #
  # Changes in these settings only affect future connections.  To make
  # sure that they are applied, they should generally be called right
  # after the Database object is instantiated and before a connection
  # is actually made. For example, to use whatever the server defaults are:
  #
  #   DB = Sequel.postgres(...)
  #   Sequel::Postgres.client_min_messages = nil
  #   Sequel::Postgres.force_standard_strings = false
  #   Sequel::Postgres.use_iso_date_format = false
  #   # A connection to the server is not made until here
  #   DB[:t].all
  #
  # The reason they can't be done earlier is that the Sequel::Postgres
  # module is not loaded until a Database object which uses PostgreSQL
  # is created.
  module Postgres
    # Array of exceptions that need to be converted.  JDBC
    # uses NativeExceptions, the native adapter uses PGError.
    CONVERTED_EXCEPTIONS = []
    
    @client_min_messages = :warning
    @force_standard_strings = true
    
    class << self
      # By default, Sequel sets the minimum level of log messages sent to the client
      # to WARNING, where PostgreSQL uses a default of NOTICE.  This is to avoid a lot
      # of mostly useless messages when running migrations, such as a couple of lines
      # for every serial primary key field.
      attr_accessor :client_min_messages

      # By default, Sequel forces the use of standard strings, so that
      # '\\' is interpreted as \\ and not \.  While PostgreSQL defaults
      # to interpreting plain strings as extended strings, this will change
      # in a future version of PostgreSQL.  Sequel assumes that SQL standard
      # strings will be used.
      attr_accessor :force_standard_strings
    end

    # Methods shared by adapter/connection instances.
    module AdapterMethods
      attr_writer :db
      
      SELECT_CURRVAL = "SELECT currval('%s')".freeze
      SELECT_CUSTOM_SEQUENCE = proc do |schema, table| <<-end_sql
        SELECT '"' || name.nspname || '".' || CASE  
            WHEN split_part(def.adsrc, '''', 2) ~ '.' THEN  
              substr(split_part(def.adsrc, '''', 2),  
                     strpos(split_part(def.adsrc, '''', 2), '.')+1) 
            ELSE split_part(def.adsrc, '''', 2)  
          END
        FROM pg_class t
        JOIN pg_namespace  name ON (t.relnamespace = name.oid)
        JOIN pg_attribute  attr ON (t.oid = attrelid)
        JOIN pg_attrdef    def  ON (adrelid = attrelid AND adnum = attnum)
        JOIN pg_constraint cons ON (conrelid = adrelid AND adnum = conkey[1])
        WHERE cons.contype = 'p'
          AND def.adsrc ~* 'nextval'
          #{"AND name.nspname = '#{schema}'" if schema}
          AND t.relname = '#{table}'
      end_sql
      end
      SELECT_PK = proc do |schema, table| <<-end_sql
        SELECT pg_attribute.attname
        FROM pg_class, pg_attribute, pg_index, pg_namespace
        WHERE pg_class.oid = pg_attribute.attrelid
          AND pg_class.relnamespace  = pg_namespace.oid
          AND pg_class.oid = pg_index.indrelid
          AND pg_index.indkey[0] = pg_attribute.attnum
          AND pg_index.indisprimary = 't'
          #{"AND pg_namespace.nspname = '#{schema}'" if schema}
          AND pg_class.relname = '#{table}'
      end_sql
      end
      SELECT_SERIAL_SEQUENCE = proc do |schema, table| <<-end_sql
        SELECT  '"' || name.nspname || '".' || seq.relname || ''
        FROM pg_class seq, pg_attribute attr, pg_depend dep,
          pg_namespace name, pg_constraint cons
        WHERE seq.oid = dep.objid
          AND seq.relnamespace  = name.oid
          AND seq.relkind = 'S'
          AND attr.attrelid = dep.refobjid
          AND attr.attnum = dep.refobjsubid
          AND attr.attrelid = cons.conrelid
          AND attr.attnum = cons.conkey[1]
          AND cons.contype = 'p'
          #{"AND name.nspname = '#{schema}'" if schema}
          AND seq.relname = '#{table}'
      end_sql
      end
      
      # Depth of the current transaction on this connection, used
      # to implement multi-level transactions with savepoints.
      attr_accessor :transaction_depth
      
      # Apply connection settings for this connection. Currently, turns
      # standard_conforming_strings ON if Postgres.force_standard_strings
      # is true.
      def apply_connection_settings
        if Postgres.force_standard_strings
          # This setting will only work on PostgreSQL 8.2 or greater
          # and we don't know the server version at this point, so
          # try it unconditionally and rescue any errors.
          execute("SET standard_conforming_strings = ON") rescue nil
        end
        if cmm = Postgres.client_min_messages
          execute("SET client_min_messages = '#{cmm.to_s.upcase}'")
        end
      end

      # Get the last inserted value for the given sequence.
      def last_insert_id(sequence)
        sql = SELECT_CURRVAL % sequence
        execute(sql) do |r|
          val = single_value(r)
          return val.to_i if val
        end
      end
      
      # Get the primary key for the given table.
      def primary_key(schema, table)
        sql = SELECT_PK[schema, table]
        execute(sql) do |r|
          return single_value(r)
        end
      end
      
      # Get the primary key and sequence for the given table.
      def sequence(schema, table)
        sql = SELECT_SERIAL_SEQUENCE[schema, table]
        execute(sql) do |r|
          seq = single_value(r)
          return seq if seq
        end
        
        sql = SELECT_CUSTOM_SEQUENCE[schema, table]
        execute(sql) do |r|
          return single_value(r)
        end
      end
    end
    
    # Methods shared by Database instances that connect to PostgreSQL.
    module DatabaseMethods
      EXCLUDE_SCHEMAS = /pg_*|information_schema/i
      PREPARED_ARG_PLACEHOLDER = LiteralString.new('$').freeze
      RE_CURRVAL_ERROR = /currval of sequence "(.*)" is not yet defined in this session|relation "(.*)" does not exist/.freeze
      SYSTEM_TABLE_REGEXP = /^pg|sql/.freeze

      # Commit an existing prepared transaction with the given transaction
      # identifier string.
      def commit_prepared_transaction(transaction_id)
        run("COMMIT PREPARED #{literal(transaction_id)}")
      end

      # Creates the function in the database.  Arguments:
      # * name : name of the function to create
      # * definition : string definition of the function, or object file for a dynamically loaded C function.
      # * opts : options hash:
      #   * :args : function arguments, can be either a symbol or string specifying a type or an array of 1-3 elements:
      #     * element 1 : argument data type
      #     * element 2 : argument name
      #     * element 3 : argument mode (e.g. in, out, inout)
      #   * :behavior : Should be IMMUTABLE, STABLE, or VOLATILE.  PostgreSQL assumes VOLATILE by default.
      #   * :cost : The estimated cost of the function, used by the query planner.
      #   * :language : The language the function uses.  SQL is the default.
      #   * :link_symbol : For a dynamically loaded see function, the function's link symbol if different from the definition argument.
      #   * :returns : The data type returned by the function.  If you are using OUT or INOUT argument modes, this is ignored.
      #     Otherwise, if this is not specified, void is used by default to specify the function is not supposed to return a value.
      #   * :rows : The estimated number of rows the function will return.  Only use if the function returns SETOF something.
      #   * :security_definer : Makes the privileges of the function the same as the privileges of the user who defined the function instead of
      #     the privileges of the user who runs the function.  There are security implications when doing this, see the PostgreSQL documentation.
      #   * :set : Configuration variables to set while the function is being run, can be a hash or an array of two pairs.  search_path is
      #     often used here if :security_definer is used.
      #   * :strict : Makes the function return NULL when any argument is NULL.
      def create_function(name, definition, opts={})
        self << create_function_sql(name, definition, opts)
      end
      
      # Create the procedural language in the database. Arguments:
      # * name : Name of the procedural language (e.g. plpgsql)
      # * opts : options hash:
      #   * :handler : The name of a previously registered function used as a call handler for this language.
      #   * :replace: Replace the installed language if it already exists (on PostgreSQL 9.0+).
      #   * :trusted : Marks the language being created as trusted, allowing unprivileged users to create functions using this language.
      #   * :validator : The name of previously registered function used as a validator of functions defined in this language.
      def create_language(name, opts={})
        self << create_language_sql(name, opts)
      end
      
      # Create a trigger in the database.  Arguments:
      # * table : the table on which this trigger operates
      # * name : the name of this trigger
      # * function : the function to call for this trigger, which should return type trigger.
      # * opts : options hash:
      #   * :after : Calls the trigger after execution instead of before.
      #   * :args : An argument or array of arguments to pass to the function.
      #   * :each_row : Calls the trigger for each row instead of for each statement.
      #   * :events : Can be :insert, :update, :delete, or an array of any of those. Calls the trigger whenever that type of statement is used.  By default,
      #     the trigger is called for insert, update, or delete.
      def create_trigger(table, name, function, opts={})
        self << create_trigger_sql(table, name, function, opts)
      end
      
      # PostgreSQL uses the :postgres database type.
      def database_type
        :postgres
      end

      # Drops the function from the database. Arguments:
      # * name : name of the function to drop
      # * opts : options hash:
      #   * :args : The arguments for the function.  See create_function_sql.
      #   * :cascade : Drop other objects depending on this function.
      #   * :if_exists : Don't raise an error if the function doesn't exist.
      def drop_function(name, opts={})
        self << drop_function_sql(name, opts)
      end
      
      # Drops a procedural language from the database.  Arguments:
      # * name : name of the procedural language to drop
      # * opts : options hash:
      #   * :cascade : Drop other objects depending on this function.
      #   * :if_exists : Don't raise an error if the function doesn't exist.
      def drop_language(name, opts={})
        self << drop_language_sql(name, opts)
      end
      
      # Remove the cached entries for primary keys and sequences when dropping a table.
      def drop_table(*names)
        names.each do |name|
          name = quote_schema_table(name)
          @primary_keys.delete(name)
          @primary_key_sequences.delete(name)
        end
        super
      end

      # Drops a trigger from the database.  Arguments:
      # * table : table from which to drop the trigger
      # * name : name of the trigger to drop
      # * opts : options hash:
      #   * :cascade : Drop other objects depending on this function.
      #   * :if_exists : Don't raise an error if the function doesn't exist.
      def drop_trigger(table, name, opts={})
        self << drop_trigger_sql(table, name, opts)
      end
      
      # Use the pg_* system tables to determine indexes on a table
      def indexes(table, opts={})
        m = output_identifier_meth
        im = input_identifier_meth
        schema, table = schema_and_table(table)
        range = 0...32
        attnums = server_version >= 80100 ? SQL::Function.new(:ANY, :ind__indkey) : range.map{|x| SQL::Subscript.new(:ind__indkey, [x])}
        ds = metadata_dataset.
          from(:pg_class___tab).
          join(:pg_index___ind, :indrelid=>:oid, im.call(table)=>:relname).
          join(:pg_class___indc, :oid=>:indexrelid).
          join(:pg_attribute___att, :attrelid=>:tab__oid, :attnum=>attnums).
          filter(:indc__relkind=>'i', :ind__indisprimary=>false, :indexprs=>nil, :indpred=>nil).
          order(:indc__relname, range.map{|x| [SQL::Subscript.new(:ind__indkey, [x]), x]}.case(32, :att__attnum)).
          select(:indc__relname___name, :ind__indisunique___unique, :att__attname___column)
        
        ds.join!(:pg_namespace___nsp, :oid=>:tab__relnamespace, :nspname=>schema.to_s) if schema
        ds.filter!(:indisvalid=>true) if server_version >= 80200
        ds.filter!(:indisready=>true, :indcheckxmin=>false) if server_version >= 80300
        
        indexes = {}
        ds.each do |r|
          i = indexes[m.call(r[:name])] ||= {:columns=>[], :unique=>r[:unique]}
          i[:columns] << m.call(r[:column])
        end
        indexes
      end

      # Dataset containing all current database locks 
      def locks
        dataset.from(:pg_class).join(:pg_locks, :relation=>:relfilenode).select(:pg_class__relname, Sequel::SQL::ColumnAll.new(:pg_locks))
      end
      
      # Return primary key for the given table.
      def primary_key(table, opts={})
        quoted_table = quote_schema_table(table)
        return @primary_keys[quoted_table] if @primary_keys.include?(quoted_table)
        @primary_keys[quoted_table] = if conn = opts[:conn]
          conn.primary_key(*schema_and_table(table))
        else
          synchronize(opts[:server]){|con| con.primary_key(*schema_and_table(table))}
        end
      end
      
      # Return the sequence providing the default for the primary key for the given table.
      def primary_key_sequence(table, opts={})
        quoted_table = quote_schema_table(table)
        return @primary_key_sequences[quoted_table] if @primary_key_sequences.include?(quoted_table)
        @primary_key_sequences[quoted_table] = if conn = opts[:conn]
          conn.sequence(*schema_and_table(table))
        else
          synchronize(opts[:server]){|con| con.sequence(*schema_and_table(table))}
        end
      end
      
      # Reset the primary key sequence for the given table, baseing it on the
      # maximum current value of the table's primary key.
      def reset_primary_key_sequence(table)
        pk = SQL::Identifier.new(primary_key(table))
        return unless seq = primary_key_sequence(table)
        db = self
        seq_ds = db.from(seq.lit)
        get{setval(seq, db[table].select{coalesce(max(pk)+seq_ds.select{:increment_by}, seq_ds.select(:min_value))}, false)}
      end

      # Rollback an existing prepared transaction with the given transaction
      # identifier string.
      def rollback_prepared_transaction(transaction_id)
        run("ROLLBACK PREPARED #{literal(transaction_id)}")
      end

      # PostgreSQL uses SERIAL psuedo-type instead of AUTOINCREMENT for
      # managing incrementing primary keys.
      def serial_primary_key_options
        {:primary_key => true, :serial => true, :type=>Integer}
      end
      
      # The version of the PostgreSQL server, used for determining capability.
      def server_version(server=nil)
        return @server_version if @server_version
        @server_version = synchronize(server) do |conn|
          (conn.server_version rescue nil) if conn.respond_to?(:server_version)
        end
        unless @server_version
          m = /PostgreSQL (\d+)\.(\d+)(?:(?:rc\d+)|\.(\d+))?/.match(fetch('SELECT version()').single_value)
          @server_version = (m[1].to_i * 10000) + (m[2].to_i * 100) + m[3].to_i
        end
        @server_version
      end
      
      # PostgreSQL supports prepared transactions (two-phase commit) if
      # max_prepared_transactions is greater than 0.
      def supports_prepared_transactions?
        return @supports_prepared_transactions if defined?(@supports_prepared_transactions)
        @supports_prepared_transactions = self['SHOW max_prepared_transactions'].get.to_i > 0
      end

      # PostgreSQL supports savepoints
      def supports_savepoints?
        true
      end

      # PostgreSQL supports transaction isolation levels
      def supports_transaction_isolation_levels?
        true
      end

      # Whether the given table exists in the database
      #
      # Options:
      # * :schema - The schema to search (default_schema by default)
      # * :server - The server to use
      def table_exists?(table, opts={})
        im = input_identifier_meth
        schema, table = schema_and_table(table)
        opts[:schema] ||= schema
        tables(opts){|ds| !ds.first(:relname=>im.call(table)).nil?}
      end
      
      # Array of symbols specifying table names in the current database.
      # The dataset used is yielded to the block if one is provided,
      # otherwise, an array of symbols of table names is returned.  
      #
      # Options:
      # * :schema - The schema to search (default_schema by default)
      # * :server - The server to use
      def tables(opts={})
        ds = metadata_dataset.from(:pg_class).filter(:relkind=>'r').select(:relname).exclude(SQL::StringExpression.like(:relname, SYSTEM_TABLE_REGEXP)).server(opts[:server]).join(:pg_namespace, :oid=>:relnamespace) 
        ds = filter_schema(ds, opts)
        m = output_identifier_meth
        block_given? ? yield(ds) : ds.map{|r| m.call(r[:relname])}
      end

      private

      # If the :prepare option is given and we aren't in a savepoint,
      # prepare the transaction for a two-phase commit.
      def commit_transaction(conn, opts={})
        if opts[:prepare] && Thread.current[:sequel_transaction_depth] <= 1
          log_connection_execute(conn, "PREPARE TRANSACTION #{literal(opts[:prepare])}")
        else
          super
        end
      end

      # SQL statement to create database function.
      def create_function_sql(name, definition, opts={})
        args = opts[:args]
        if !opts[:args].is_a?(Array) || !opts[:args].any?{|a| Array(a).length == 3 and %w'OUT INOUT'.include?(a[2].to_s)}
          returns = opts[:returns] || 'void'
        end
        language = opts[:language] || 'SQL'
        <<-END
        CREATE#{' OR REPLACE' if opts[:replace]} FUNCTION #{name}#{sql_function_args(args)}
        #{"RETURNS #{returns}" if returns}
        LANGUAGE #{language}
        #{opts[:behavior].to_s.upcase if opts[:behavior]}
        #{'STRICT' if opts[:strict]}
        #{'SECURITY DEFINER' if opts[:security_definer]}
        #{"COST #{opts[:cost]}" if opts[:cost]}
        #{"ROWS #{opts[:rows]}" if opts[:rows]}
        #{opts[:set].map{|k,v| " SET #{k} = #{v}"}.join("\n") if opts[:set]}
        AS #{literal(definition.to_s)}#{", #{literal(opts[:link_symbol].to_s)}" if opts[:link_symbol]}
        END
      end
      
      # SQL for creating a procedural language.
      def create_language_sql(name, opts={})
        "CREATE#{' OR REPLACE' if opts[:replace] && server_version >= 90000}#{' TRUSTED' if opts[:trusted]} LANGUAGE #{name}#{" HANDLER #{opts[:handler]}" if opts[:handler]}#{" VALIDATOR #{opts[:validator]}" if opts[:validator]}"
      end
      
      # SQL for creating a database trigger. 
      def create_trigger_sql(table, name, function, opts={})
        events = opts[:events] ? Array(opts[:events]) : [:insert, :update, :delete]
        whence = opts[:after] ? 'AFTER' : 'BEFORE'
        "CREATE TRIGGER #{name} #{whence} #{events.map{|e| e.to_s.upcase}.join(' OR ')} ON #{quote_schema_table(table)}#{' FOR EACH ROW' if opts[:each_row]} EXECUTE PROCEDURE #{function}(#{Array(opts[:args]).map{|a| literal(a)}.join(', ')})"
      end
      
      # The errors that the main adapters can raise, depends on the adapter being used
      def database_error_classes
        CONVERTED_EXCEPTIONS
      end
      
      # SQL for dropping a function from the database. 
      def drop_function_sql(name, opts={})
        "DROP FUNCTION#{' IF EXISTS' if opts[:if_exists]} #{name}#{sql_function_args(opts[:args])}#{' CASCADE' if opts[:cascade]}"
      end
      
      # SQL for dropping a procedural language from the database.
      def drop_language_sql(name, opts={})
        "DROP LANGUAGE#{' IF EXISTS' if opts[:if_exists]} #{name}#{' CASCADE' if opts[:cascade]}"
      end

      # Always CASCADE the table drop
      def drop_table_sql(name)
        "DROP TABLE #{quote_schema_table(name)} CASCADE"
      end
      
      # SQL for dropping a trigger from the database.
      def drop_trigger_sql(table, name, opts={})
        "DROP TRIGGER#{' IF EXISTS' if opts[:if_exists]} #{name} ON #{quote_schema_table(table)}#{' CASCADE' if opts[:cascade]}"
      end

      # If opts includes a :schema option, or a default schema is used, restrict the dataset to
      # that schema.  Otherwise, just exclude the default PostgreSQL schemas except for public.
      def filter_schema(ds, opts)
        if schema = opts[:schema] || default_schema
          ds.filter(:pg_namespace__nspname=>schema.to_s)
        else
          ds.exclude(:pg_namespace__nspname=>EXCLUDE_SCHEMAS)
        end
      end
      
      # PostgreSQL folds unquoted identifiers to lowercase, so it shouldn't need to upcase identifiers on input.
      def identifier_input_method_default
        nil
      end
      
      # PostgreSQL folds unquoted identifiers to lowercase, so it shouldn't need to upcase identifiers on output.
      def identifier_output_method_default
        nil
      end

      # PostgreSQL specific index SQL.
      def index_definition_sql(table_name, index)
        cols = index[:columns]
        index_name = index[:name] || default_index_name(table_name, cols)
        expr = if o = index[:opclass] 
          "(#{Array(cols).map{|c| "#{literal(c)} #{o}"}.join(', ')})"
        else
          literal(Array(cols))
        end
        unique = "UNIQUE " if index[:unique]
        index_type = index[:type]
        filter = index[:where] || index[:filter]
        filter = " WHERE #{filter_expr(filter)}" if filter
        case index_type
        when :full_text
          expr = "(to_tsvector(#{literal(index[:language] || 'simple')}, #{dataset.send(:full_text_string_join, cols)}))"
          index_type = :gin
        when :spatial
          index_type = :gist
        end
        "CREATE #{unique}INDEX #{quote_identifier(index_name)} ON #{quote_schema_table(table_name)} #{"USING #{index_type} " if index_type}#{expr}#{filter}"
      end
      
      # The result of the insert for the given table and values.  If values
      # is an array, assume the first column is the primary key and return
      # that.  If values is a hash, lookup the primary key for the table.  If
      # the primary key is present in the hash, return its value.  Otherwise,
      # look up the sequence for the table's primary key.  If one exists,
      # return the last value the of the sequence for the connection.
      def insert_result(conn, table, values)
        case values
        when Hash
          return nil unless pk = primary_key(table, :conn=>conn)
          if pk and pkv = values[pk.to_sym]
            pkv
          else
            begin
              if seq = primary_key_sequence(table, :conn=>conn)
                conn.last_insert_id(seq)
              end
            rescue Exception => e
              raise_error(e, :classes=>CONVERTED_EXCEPTIONS) unless RE_CURRVAL_ERROR.match(e.message)
            end
          end
        when Array
          values.first
        else
          nil
        end
      end

      # Don't log, since logging is done by the underlying connection.
      def log_connection_execute(conn, sql) 
        conn.execute(sql)
      end
      
      # Use a dollar sign instead of question mark for the argument
      # placeholder.
      def prepared_arg_placeholder
        PREPARED_ARG_PLACEHOLDER
      end
      
      # SQL DDL statement for renaming a table. PostgreSQL doesn't allow you to change a table's schema in
      # a rename table operation, so speciying a new schema in new_name will not have an effect.
      def rename_table_sql(name, new_name)
        "ALTER TABLE #{quote_schema_table(name)} RENAME TO #{quote_identifier(schema_and_table(new_name).last)}"
      end 

      # PostgreSQL's autoincrementing primary keys are of type integer or bigint
      # using a nextval function call as a default.
      def schema_autoincrementing_primary_key?(schema)
        super and schema[:db_type] =~ /\A(?:integer|bigint)\z/io and schema[:default]=~/\Anextval/io
      end

      # The dataset used for parsing table schemas, using the pg_* system catalogs.
      def schema_parse_table(table_name, opts)
        m = output_identifier_meth
        m2 = input_identifier_meth
        ds = metadata_dataset.select(:pg_attribute__attname___name,
            SQL::Function.new(:format_type, :pg_type__oid, :pg_attribute__atttypmod).as(:db_type),
            SQL::Function.new(:pg_get_expr, :pg_attrdef__adbin, :pg_class__oid).as(:default),
            SQL::BooleanExpression.new(:NOT, :pg_attribute__attnotnull).as(:allow_null),
            SQL::Function.new(:COALESCE, SQL::BooleanExpression.from_value_pairs(:pg_attribute__attnum => SQL::Function.new(:ANY, :pg_index__indkey)), false).as(:primary_key)).
          from(:pg_class).
          join(:pg_attribute, :attrelid=>:oid).
          join(:pg_type, :oid=>:atttypid).
          join(:pg_namespace, :oid=>:pg_class__relnamespace).
          left_outer_join(:pg_attrdef, :adrelid=>:pg_class__oid, :adnum=>:pg_attribute__attnum).
          left_outer_join(:pg_index, :indrelid=>:pg_class__oid, :indisprimary=>true).
          filter(:pg_attribute__attisdropped=>false).
          filter{|o| o.pg_attribute__attnum > 0}.
          filter(:pg_class__relname=>m2.call(table_name)).
          order(:pg_attribute__attnum)
        ds = filter_schema(ds, opts)
        ds.map do |row|
          row[:default] = nil if blank_object?(row[:default])
          row[:type] = schema_column_type(row[:db_type])
          [m.call(row.delete(:name)), row]
        end
      end

      # Turns an array of argument specifiers into an SQL fragment used for function arguments.  See create_function_sql.
      def sql_function_args(args)
        "(#{Array(args).map{|a| Array(a).reverse.join(' ')}.join(', ')})"
      end
      
      # Handle bigserial type if :serial option is present
      def type_literal_generic_bignum(column)
        column[:serial] ? :bigserial : super
      end

      # PostgreSQL uses the bytea data type for blobs
      def type_literal_generic_file(column)
        :bytea
      end

      # Handle serial type if :serial option is present
      def type_literal_generic_integer(column)
        column[:serial] ? :serial : super
      end

      # PostgreSQL prefers the text datatype.  If a fixed size is requested,
      # the char type is used.  If the text type is specifically
      # disallowed or there is a size specified, use the varchar type.
      # Otherwise use the type type.
      def type_literal_generic_string(column)
        if column[:fixed]
          "char(#{column[:size]||255})"
        elsif column[:text] == false or column[:size]
          "varchar(#{column[:size]||255})"
        else
          :text
        end
      end
    end
    
    # Instance methods for datasets that connect to a PostgreSQL database.
    module DatasetMethods
      ACCESS_SHARE = 'ACCESS SHARE'.freeze
      ACCESS_EXCLUSIVE = 'ACCESS EXCLUSIVE'.freeze
      BOOL_FALSE = 'false'.freeze
      BOOL_TRUE = 'true'.freeze
      COMMA_SEPARATOR = ', '.freeze
      DELETE_CLAUSE_METHODS = Dataset.clause_methods(:delete, %w'from using where')
      EXCLUSIVE = 'EXCLUSIVE'.freeze
      EXPLAIN = 'EXPLAIN '.freeze
      EXPLAIN_ANALYZE = 'EXPLAIN ANALYZE '.freeze
      FOR_SHARE = ' FOR SHARE'.freeze
      LOCK = 'LOCK TABLE %s IN %s MODE'.freeze
      NULL = LiteralString.new('NULL').freeze
      PG_TIMESTAMP_FORMAT = "TIMESTAMP '%Y-%m-%d %H:%M:%S".freeze
      QUERY_PLAN = 'QUERY PLAN'.to_sym
      ROW_EXCLUSIVE = 'ROW EXCLUSIVE'.freeze
      ROW_SHARE = 'ROW SHARE'.freeze
      SELECT_CLAUSE_METHODS = Dataset.clause_methods(:select, %w'distinct columns from join where group having compounds order limit lock')
      SELECT_CLAUSE_METHODS_84 = Dataset.clause_methods(:select, %w'with distinct columns from join where group having window compounds order limit lock')
      SHARE = 'SHARE'.freeze
      SHARE_ROW_EXCLUSIVE = 'SHARE ROW EXCLUSIVE'.freeze
      SHARE_UPDATE_EXCLUSIVE = 'SHARE UPDATE EXCLUSIVE'.freeze
      SQL_WITH_RECURSIVE = "WITH RECURSIVE ".freeze
      UPDATE_CLAUSE_METHODS = Dataset.clause_methods(:update, %w'table set from where')
      
      # Shared methods for prepared statements when used with PostgreSQL databases.
      module PreparedStatementMethods
        # Override insert action to use RETURNING if the server supports it.
        def prepared_sql
          return @prepared_sql if @prepared_sql
          super
          if @prepared_type == :insert and !@opts[:disable_insert_returning] and server_version >= 80200
            @prepared_sql = insert_returning_pk_sql(*@prepared_modify_values)
            meta_def(:insert_returning_pk_sql){|*args| prepared_sql}
          end
          @prepared_sql
        end
      end

      # Add the disable_insert_returning! mutation method
      def self.extended(obj)
        obj.def_mutation_method(:disable_insert_returning)
      end

      # Add the disable_insert_returning! mutation method
      def self.included(mod)
        mod.def_mutation_method(:disable_insert_returning)
      end

      # Return the results of an ANALYZE query as a string
      def analyze
        explain(:analyze=>true)
      end
      
      # Handle converting the ruby xor operator (^) into the
      # PostgreSQL xor operator (#).
      def complex_expression_sql(op, args)
        case op
        when :^
          "(#{literal(args.at(0))} # #{literal(args.at(1))})"
        else
          super
        end
      end

      # Disable the use of INSERT RETURNING, even if the server supports it
      def disable_insert_returning
        clone(:disable_insert_returning=>true)
      end

      # Return the results of an EXPLAIN query as a string
      def explain(opts={})
        with_sql((opts[:analyze] ? EXPLAIN_ANALYZE : EXPLAIN) + select_sql).map(QUERY_PLAN).join("\r\n")
      end
      
      # Return a cloned dataset which will use FOR SHARE to lock returned rows.
      def for_share
        lock_style(:share)
      end
      
      # PostgreSQL specific full text search syntax, using tsearch2 (included
      # in 8.3 by default, and available for earlier versions as an add-on).
      def full_text_search(cols, terms, opts = {})
        lang = opts[:language] || 'simple'
        filter("to_tsvector(#{literal(lang)}, #{full_text_string_join(cols)}) @@ to_tsquery(#{literal(lang)}, #{literal(Array(terms).join(' | '))})")
      end
      
      # Insert given values into the database.
      def insert(*values)
        if @opts[:sql]
          execute_insert(insert_sql(*values))
        elsif @opts[:disable_insert_returning] || server_version < 80200
          execute_insert(insert_sql(*values), :table=>opts[:from].first, :values=>values.size == 1 ? values.first : values)
        else
          clone(default_server_opts(:sql=>insert_returning_pk_sql(*values))).single_value
        end
      end

      # Use the RETURNING clause to return the columns listed in returning.
      def insert_returning_sql(returning, *values)
        "#{insert_sql(*values)} RETURNING #{column_list(Array(returning))}"
      end

      # Insert a record returning the record inserted
      def insert_select(*values)
        return if opts[:disable_insert_returning] || server_version < 80200
        naked.clone(default_server_opts(:sql=>insert_returning_sql(nil, *values))).single_record
      end

      # Locks all tables in the dataset's FROM clause (but not in JOINs) with
      # the specified mode (e.g. 'EXCLUSIVE').  If a block is given, starts
      # a new transaction, locks the table, and yields.  If a block is not given
      # just locks the tables.  Note that PostgreSQL will probably raise an error
      # if you lock the table outside of an existing transaction.  Returns nil.
      def lock(mode, opts={})
        if block_given? # perform locking inside a transaction and yield to block
          @db.transaction(opts){lock(mode, opts); yield}
        else
          @db.execute(LOCK % [source_list(@opts[:from]), mode], opts) # lock without a transaction
        end
        nil
      end
      
      # For PostgreSQL version > 8.2, allow inserting multiple rows at once.
      def multi_insert_sql(columns, values)
        return super if server_version < 80200
        
        # postgresql 8.2 introduces support for multi-row insert
        [insert_sql(columns, LiteralString.new('VALUES ' + values.map {|r| literal(Array(r))}.join(COMMA_SEPARATOR)))]
      end
      
      # DISTINCT ON is a PostgreSQL extension
      def supports_distinct_on?
        true
      end
      
      # PostgreSQL supports modifying joined datasets
      def supports_modifying_joins?
        true
      end

      # PostgreSQL supports timezones in literal timestamps
      def supports_timestamp_timezones?
        true
      end
      
      # PostgreSQL 8.4+ supports window functions
      def supports_window_functions?
        server_version >= 80400
      end

      # Return a clone of the dataset with an addition named window that can be referenced in window functions.
      def window(name, opts)
        clone(:window=>(@opts[:window]||[]) + [[name, SQL::Window.new(opts)]])
      end
      
      private
      
      # PostgreSQL allows deleting from joined datasets
      def delete_clause_methods
        DELETE_CLAUSE_METHODS
      end 

      # Only include the primary table in the main delete clause
      def delete_from_sql(sql)
        sql << " FROM #{source_list(@opts[:from][0..0])}"
      end

      # Use USING to specify additional tables in a delete query
      def delete_using_sql(sql)
        join_from_sql(:USING, sql)
      end

      # Use the RETURNING clause to return the primary key of the inserted record, if it exists
      def insert_returning_pk_sql(*values)
        pk = db.primary_key(opts[:from].first) if opts[:from] && !opts[:from].empty?
        insert_returning_sql(pk ? Sequel::SQL::Identifier.new(pk) : NULL, *values)
      end
      
      # For multiple table support, PostgreSQL requires at least
      # two from tables, with joins allowed.
      def join_from_sql(type, sql)
        if(from = @opts[:from][1..-1]).empty?
          raise(Error, 'Need multiple FROM tables if updating/deleting a dataset with JOINs') if @opts[:join]
        else
          sql << " #{type} #{source_list(from)}"
          select_join_sql(sql)
        end
      end

      # Use a generic blob quoting method, hopefully overridden in one of the subadapter methods
      def literal_blob(v)
        "'#{v.gsub(/[\000-\037\047\134\177-\377]/n){|b| "\\#{("%o" % b[0..1].unpack("C")[0]).rjust(3, '0')}"}}'"
      end

      # PostgreSQL uses FALSE for false values
      def literal_false
        BOOL_FALSE
      end

      # Assume that SQL standard quoting is on, per Sequel's defaults
      def literal_string(v)
        "'#{v.gsub("'", "''")}'"
      end

      # PostgreSQL uses FALSE for false values
      def literal_true
        BOOL_TRUE
      end

      # The order of clauses in the SELECT SQL statement
      def select_clause_methods
        server_version >= 80400 ? SELECT_CLAUSE_METHODS_84 : SELECT_CLAUSE_METHODS
      end
      
      # Support FOR SHARE locking when using the :share lock style.
      def select_lock_sql(sql)
        @opts[:lock] == :share ? (sql << FOR_SHARE) : super
      end

      # SQL fragment for named window specifications
      def select_window_sql(sql)
        sql << " WINDOW #{@opts[:window].map{|name, window| "#{literal(name)} AS #{literal(window)}"}.join(', ')}" if @opts[:window]
      end
      
      # Use WITH RECURSIVE instead of WITH if any of the CTEs is recursive
      def select_with_sql_base
        opts[:with].any?{|w| w[:recursive]} ? SQL_WITH_RECURSIVE : super
      end
      
      # The version of the database server
      def server_version
        db.server_version(@opts[:server])
      end

      # Concatenate the expressions with a space in between
      def full_text_string_join(cols)
        cols = Array(cols).map{|x| SQL::Function.new(:COALESCE, x, '')}
        cols = cols.zip([' '] * cols.length).flatten
        cols.pop
        literal(SQL::StringExpression.new(:'||', *cols))
      end

      # PostgreSQL splits the main table from the joined tables
      def update_clause_methods
        UPDATE_CLAUSE_METHODS
      end

      # Use FROM to specify additional tables in an update query
      def update_from_sql(sql)
        join_from_sql(:FROM, sql)
      end

      # Only include the primary table in the main update clause
      def update_table_sql(sql)
        sql << " #{source_list(@opts[:from][0..0])}"
      end
    end
  end
end
