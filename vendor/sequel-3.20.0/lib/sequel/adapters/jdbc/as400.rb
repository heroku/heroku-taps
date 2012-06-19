module Sequel
  module JDBC
    # Database and Dataset support for AS400 databases accessed via JDBC.
    module AS400
      # Instance methods for AS400 Database objects accessed via JDBC.
      module DatabaseMethods
        TRANSACTION_BEGIN = 'Transaction.begin'.freeze
        TRANSACTION_COMMIT = 'Transaction.commit'.freeze
        TRANSACTION_ROLLBACK = 'Transaction.rollback'.freeze
        
        # AS400 uses the :as400 database type.
        def database_type
          :as400
        end

        # Return Sequel::JDBC::AS400::Dataset object with the given opts.
        def dataset(opts=nil)
          Sequel::JDBC::AS400::Dataset.new(self, opts)
        end

        # TODO: Fix for AS400
        def last_insert_id(conn, opts={})
          nil
        end

        # AS400 supports transaction isolation levels
        def supports_transaction_isolation_levels?
          true
        end

        private

        # Use JDBC connection's setAutoCommit to false to start transactions
        def begin_transaction(conn, opts={})
          set_transaction_isolation(conn, opts)
          log_yield(TRANSACTION_BEGIN){conn.setAutoCommit(false)}
          conn
        end

        # Use JDBC connection's commit method to commit transactions
        def commit_transaction(conn, opts={})
          log_yield(TRANSACTION_COMMIT){conn.commit}
        end

        # Use JDBC connection's setAutoCommit to true to enable default
        # auto-commit mode
        def remove_transaction(conn)
          conn.setAutoCommit(true) if conn
          @transactions.delete(Thread.current)
        end

        # Use JDBC connection's rollback method to rollback transactions
        def rollback_transaction(conn, opts={})
          log_yield(TRANSACTION_ROLLBACK){conn.rollback}
        end
      end
      
      # Dataset class for AS400 datasets accessed via JDBC.
      class Dataset < JDBC::Dataset
        WILDCARD = Sequel::LiteralString.new('*').freeze
        
        # AS400 needs to use a couple of subselects for queries with offsets.
        def select_sql
          return super unless o = @opts[:offset]
          l = @opts[:limit]
          order = @opts[:order]
          dsa1 = dataset_alias(1)
          dsa2 = dataset_alias(2)
          rn = row_number_column
          irn = Sequel::SQL::Identifier.new(rn).qualify(dsa2)
          subselect_sql(unlimited.
              from_self(:alias=>dsa1).
              select_more(Sequel::SQL::QualifiedIdentifier.new(dsa1, WILDCARD),
              Sequel::SQL::WindowFunction.new(SQL::Function.new(:ROW_NUMBER), Sequel::SQL::Window.new(:order=>order)).as(rn)).
              from_self(:alias=>dsa2).
              select(Sequel::SQL::QualifiedIdentifier.new(dsa2, WILDCARD)).
              where(l ? ((irn > o) & (irn <= l + o)) : (irn > o))) # Leave off limit in case of limit(nil, offset)
        end

        # Modify the sql to limit the number of rows returned
        def select_limit_sql(sql)
          if @opts[:limit]
            sql << " FETCH FIRST ROW ONLY" if @opts[:limit] == 1
            sql << " FETCH FIRST #{@opts[:limit]} ROWS ONLY" if @opts[:limit] > 1
          end
        end
          
        def supports_window_functions?
          true
        end
          
        private
        
        # The alias to use for the row_number column when emulating LIMIT and OFFSET
        def row_number_column
          :x_sequel_row_number_x
        end
      end
    end
  end
end
