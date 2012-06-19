require 'data_objects'

module Sequel
  # Module holding the DataObjects support for Sequel.  DataObjects is a
  # ruby library with a standard API for accessing databases.
  #
  # The DataObjects adapter currently supports PostgreSQL, MySQL, and
  # SQLite:
  #
  # *  Sequel.connect('do:sqlite3::memory:')
  # *  Sequel.connect('do:postgres://user:password@host/database')
  # *  Sequel.connect('do:mysql://user:password@host/database')
  module DataObjects
    # Contains procs keyed on sub adapter type that extend the
    # given database object so it supports the correct database type.
    DATABASE_SETUP = {:postgres=>proc do |db|
        Sequel.tsk_require 'do_postgres'
        Sequel.ts_require 'adapters/do/postgres'
        db.extend(Sequel::DataObjects::Postgres::DatabaseMethods)
      end,
      :mysql=>proc do |db|
        Sequel.tsk_require 'do_mysql'
        Sequel.ts_require 'adapters/do/mysql'
        db.extend(Sequel::DataObjects::MySQL::DatabaseMethods)
      end,
      :sqlite3=>proc do |db|
        Sequel.tsk_require 'do_sqlite3'
        Sequel.ts_require 'adapters/do/sqlite'
        db.extend(Sequel::DataObjects::SQLite::DatabaseMethods)
      end
    }
      
    # DataObjects uses it's own internal connection pooling in addition to the
    # pooling that Sequel uses.  You should make sure that you don't set
    # the connection pool size to more than 8 for a
    # Sequel::DataObjects::Database object, or hack DataObjects (or Extlib) to
    # use a pool size at least as large as the pool size being used by Sequel.
    class Database < Sequel::Database
      set_adapter_scheme :do
      
      # Call the DATABASE_SETUP proc directly after initialization,
      # so the object always uses sub adapter specific code.  Also,
      # raise an error immediately if the connection doesn't have a
      # uri, since DataObjects requires one.
      def initialize(opts)
        super
        raise(Error, "No connection string specified") unless uri
        if prok = DATABASE_SETUP[subadapter.to_sym]
          prok.call(self)
        end
      end
      
      # Setup a DataObjects::Connection to the database.
      def connect(server)
        setup_connection(::DataObjects::Connection.new(uri(server_opts(server))))
      end
      
      # Return a Sequel::DataObjects::Dataset object for this database.
      def dataset(opts = nil)
        DataObjects::Dataset.new(self, opts)
      end
    
      # Execute the given SQL.  If a block is given, the DataObjects::Reader
      # created is yielded to it. A block should not be provided unless a
      # a SELECT statement is being used (or something else that returns rows).
      # Otherwise, the return value is the insert id if opts[:type] is :insert,
      # or the number of affected rows, otherwise.
      def execute(sql, opts={})
        synchronize(opts[:server]) do |conn|
          begin
            command = conn.create_command(sql)
            res = log_yield(sql){block_given? ? command.execute_reader : command.execute_non_query}
          rescue ::DataObjects::Error => e
            raise_error(e)
          end
          if block_given?
            begin
              yield(res)
            ensure
             res.close if res
            end
          elsif opts[:type] == :insert
            res.insert_id
          else
            res.affected_rows
          end
        end
      end
      
      # Execute the SQL on the this database, returning the number of affected
      # rows.
      def execute_dui(sql, opts={})
        execute(sql, opts)
      end
      
      # Execute the SQL on this database, returning the primary key of the
      # table being inserted to.
      def execute_insert(sql, opts={})
        execute(sql, opts.merge(:type=>:insert))
      end
      
      # Return the subadapter type for this database, i.e. sqlite3 for
      # do:sqlite3::memory:.
      def subadapter
        uri.split(":").first
      end
      
      # Return the DataObjects URI for the Sequel URI, removing the do:
      # prefix.
      def uri(opts={})
        opts = @opts.merge(opts)
        (opts[:uri] || opts[:url]).sub(/\Ado:/, '')
      end

      private
      
      # DataObjects uses a special transaction object to keep track of
      # transactions.  Unfortunately, it tries to create a new connection
      # to do a transaction.  So we close the connection created and
      # substitute our own.
      def begin_transaction(conn, opts={})
        return super if supports_savepoints?
        log_yield(TRANSACTION_BEGIN) do
          t = ::DataObjects::Transaction.create_for_uri(uri)
          t.instance_variable_get(:@connection).close
          t.instance_variable_set(:@connection, conn)
          t.begin
          t
        end
      end
      
      # DataObjects requires transactions be prepared before being
      # committed, so we do that.
      def commit_transaction(t, opts={})
        return super if supports_savepoints?
        log_yield(TRANSACTION_ROLLBACK) do
          t.prepare
          t.commit 
        end
      end
      
      # Method to call on a statement object to execute SQL that does
      # not return any rows.
      def connection_execute_method
        :execute_non_query
      end
      
      # Close the given database connection.
      def disconnect_connection(c)
        c.close
      end
      
      # Execute SQL on the connection by creating a command first
      def log_connection_execute(conn, sql)
        log_yield(sql){conn.create_command(sql).execute_non_query}
      end
      
      # We use the transactions rollback method to rollback.
      def rollback_transaction(t, opts={})
        return super if supports_savepoints?
        log_yield(TRANSACTION_COMMIT){t.rollback}
      end
      
      # Allow extending the given connection when it is first created.
      # By default, just returns the connection.
      def setup_connection(conn)
        conn
      end
    end
    
    # Dataset class for Sequel::DataObjects::Database objects.
    class Dataset < Sequel::Dataset
      # Execute the SQL on the database and yield the rows as hashes
      # with symbol keys.
      def fetch_rows(sql)
        execute(sql) do |reader|
          cols = @columns = reader.fields.map{|f| output_identifier(f)}
          while(reader.next!) do
            h = {}
            cols.zip(reader.values).each{|k, v| h[k] = v}
            yield h
          end
        end
        self
      end
    end
  end
end
