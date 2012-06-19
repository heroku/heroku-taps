module Sequel
  class Dataset
    # ---------------------
    # :section: Miscellaneous methods
    # These methods don't fit cleanly into another section.
    # ---------------------
    
    NOTIMPL_MSG = "This method must be overridden in Sequel adapters".freeze
    ARRAY_ACCESS_ERROR_MSG = 'You cannot call Dataset#[] with an integer or with no arguments.'.freeze
    ARG_BLOCK_ERROR_MSG = 'Must use either an argument or a block, not both'.freeze
    IMPORT_ERROR_MSG = 'Using Sequel::Dataset#import an empty column array is not allowed'.freeze
    
    # The database related to this dataset.  This is the Database instance that
    # will execute all of this dataset's queries.
    attr_accessor :db

    # The hash of options for this dataset, keys are symbols.
    attr_accessor :opts
    
    # Constructs a new Dataset instance with an associated database and 
    # options. Datasets are usually constructed by invoking the Database#[] method:
    #
    #   DB[:posts]
    #
    # Sequel::Dataset is an abstract class that is not useful by itself. Each
    # database adaptor provides a subclass of Sequel::Dataset, and has
    # the Database#dataset method return an instance of that subclass.
    def initialize(db, opts = nil)
      @db = db
      @quote_identifiers = db.quote_identifiers? if db.respond_to?(:quote_identifiers?)
      @identifier_input_method = db.identifier_input_method if db.respond_to?(:identifier_input_method)
      @identifier_output_method = db.identifier_output_method if db.respond_to?(:identifier_output_method)
      @opts = opts || {}
      @row_proc = nil
    end
    
    # Define a hash value such that datasets with the same DB, opts, and SQL
    # will be consider equal.
    def ==(o)
      o.is_a?(self.class) && db == o.db  && opts == o.opts && sql == o.sql
    end

    # Alias for ==
    def eql?(o)
      self == o
    end
    
    # Return the dataset as an aliased expression with the given alias. You can
    # use this as a FROM or JOIN dataset, or as a column if this dataset
    # returns a single row and column.
    #
    #   DB.from(DB[:table].as(:b)) # SELECT * FROM (SELECT * FROM table) AS b
    def as(aliaz)
      ::Sequel::SQL::AliasedExpression.new(self, aliaz)
    end
    
    # Yield a dataset for each server in the connection pool that is tied to that server.
    # Intended for use in sharded environments where all servers need to be modified
    # with the same data:
    #
    #   DB[:configs].where(:key=>'setting').each_server{|ds| ds.update(:value=>'new_value')}
    def each_server
      db.servers.each{|s| yield server(s)}
    end
   
    # Alias of +first_source_alias+
    def first_source
      first_source_alias
    end

    # The first source (primary table) for this dataset.  If the dataset doesn't
    # have a table, raises an +Error+.  If the table is aliased, returns the aliased name.
    #
    #   DB[:table].first_source_alias
    #   # => :table
    #
    #   DB[:table___t].first_source_alias
    #   # => :t
    def first_source_alias
      source = @opts[:from]
      if source.nil? || source.empty?
        raise Error, 'No source specified for query'
      end
      case s = source.first
      when SQL::AliasedExpression
        s.aliaz
      when Symbol
        sch, table, aliaz = split_symbol(s)
        aliaz ? aliaz.to_sym : s
      else
        s
      end
    end
    
    # The first source (primary table) for this dataset.  If the dataset doesn't
    # have a table, raises an error.  If the table is aliased, returns the original
    # table, not the alias
    #
    #   DB[:table].first_source_alias
    #   # => :table
    #
    #   DB[:table___t].first_source_alias
    #   # => :table
    def first_source_table
      source = @opts[:from]
      if source.nil? || source.empty?
        raise Error, 'No source specified for query'
      end
      case s = source.first
      when SQL::AliasedExpression
        s.expression
      when Symbol
        sch, table, aliaz = split_symbol(s)
        aliaz ? (sch ? SQL::QualifiedIdentifier.new(sch, table) : table.to_sym) : s
      else
        s
      end
    end

    # Define a hash value such that datasets with the same DB, opts, and SQL
    # will have the same hash value
    def hash
      [db, opts.sort_by{|k| k.to_s}, sql].hash
    end
    
    # Returns a string representation of the dataset including the class name 
    # and the corresponding SQL select statement.
    def inspect
      "#<#{self.class}: #{sql.inspect}>"
    end
    
    # Splits a possible implicit alias in C, handling both SQL::AliasedExpressions
    # and Symbols.  Returns an array of two elements, with the first being the
    # main expression, and the second being the alias.
    def split_alias(c)
      case c
      when Symbol
        c_table, column, aliaz = split_symbol(c)
        [c_table ? SQL::QualifiedIdentifier.new(c_table, column.to_sym) : column.to_sym, aliaz]
      when SQL::AliasedExpression
        [c.expression, c.aliaz]
      else
        [c, nil]
      end
    end

    # Creates a unique table alias that hasn't already been used in the dataset.
    # table_alias can be any type of object accepted by alias_symbol.
    # The symbol returned will be the implicit alias in the argument,
    # possibly appended with "_N" if the implicit alias has already been
    # used, where N is an integer starting at 0 and increasing until an
    # unused one is found.
    #
    #   DB[:table].unused_table_alias(:t)
    #   # => :t
    #
    #   DB[:table].unused_table_alias(:table)
    #   # => :table_0
    #
    #   DB[:table, :table_0].unused_table_alias(:table)
    #   # => :table_1
    def unused_table_alias(table_alias)
      table_alias = alias_symbol(table_alias)
      used_aliases = []
      used_aliases += opts[:from].map{|t| alias_symbol(t)} if opts[:from]
      used_aliases += opts[:join].map{|j| j.table_alias ? alias_alias_symbol(j.table_alias) : alias_symbol(j.table)} if opts[:join]
      if used_aliases.include?(table_alias)
        i = 0
        loop do
          ta = :"#{table_alias}_#{i}"
          return ta unless used_aliases.include?(ta)
          i += 1 
        end
      else
        table_alias
      end
    end
  end
end
