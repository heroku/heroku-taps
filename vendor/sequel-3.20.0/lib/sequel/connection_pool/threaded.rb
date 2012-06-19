# A connection pool allowing multi-threaded access to a pool of connections.
# This is the default connection pool used by Sequel.
class Sequel::ThreadedConnectionPool < Sequel::ConnectionPool
  # The maximum number of connections this pool will create (per shard/server
  # if sharding).
  attr_reader :max_size
  
  # An array of connections that are available for use by the pool.
  attr_reader :available_connections
  
  # A hash with thread keys and connection values for currently allocated
  # connections.
  attr_reader :allocated

  # The following additional options are respected:
  # * :max_connections - The maximum number of connections the connection pool
  #   will open (default 4)
  # * :pool_sleep_time - The amount of time to sleep before attempting to acquire
  #   a connection again (default 0.001)
  # * :pool_timeout - The amount of seconds to wait to acquire a connection
  #   before raising a PoolTimeoutError (default 5)
  def initialize(opts = {}, &block)
    super
    @max_size = Integer(opts[:max_connections] || 4)
    raise(Sequel::Error, ':max_connections must be positive') if @max_size < 1
    @mutex = Mutex.new  
    @available_connections = []
    @allocated = {}
    @timeout = Integer(opts[:pool_timeout] || 5)
    @sleep_time = Float(opts[:pool_sleep_time] || 0.001)
  end
  
  # The total number of connections opened for the given server, should
  # be equal to available_connections.length + allocated.length.
  def size
    @allocated.length + @available_connections.length
  end
  
  # Removes all connections currently available on all servers, optionally
  # yielding each connection to the given block. This method has the effect of 
  # disconnecting from the database, assuming that no connections are currently
  # being used.
  # 
  # Once a connection is requested using #hold, the connection pool
  # creates new connections to the database.
  def disconnect(opts={}, &block)
    block ||= @disconnection_proc
    sync do
      @available_connections.each{|conn| block.call(conn)} if block
      @available_connections.clear
    end
  end
  
  # Chooses the first available connection to the given server, or if none are
  # available, creates a new connection.  Passes the connection to the supplied
  # block:
  # 
  #   pool.hold {|conn| conn.execute('DROP TABLE posts')}
  # 
  # Pool#hold is re-entrant, meaning it can be called recursively in
  # the same thread without blocking.
  #
  # If no connection is immediately available and the pool is already using the maximum
  # number of connections, Pool#hold will block until a connection
  # is available or the timeout expires.  If the timeout expires before a
  # connection can be acquired, a Sequel::PoolTimeout is 
  # raised.
  def hold(server=nil)
    t = Thread.current
    if conn = owned_connection(t)
      return yield(conn)
    end
    begin
      unless conn = acquire(t)
        time = Time.now
        timeout = time + @timeout
        sleep_time = @sleep_time
        sleep sleep_time
        until conn = acquire(t)
          raise(::Sequel::PoolTimeout) if Time.now > timeout
          sleep sleep_time
        end
      end
      yield conn
    rescue Sequel::DatabaseDisconnectError
      @disconnection_proc.call(conn) if @disconnection_proc && conn
      @allocated.delete(t)
      conn = nil
      raise
    ensure
      sync{release(t)} if conn
    end
  end
  
  private

  # Assigns a connection to the supplied thread for the given server, if one
  # is available. The calling code should NOT already have the mutex when
  # calling this.
  def acquire(thread)
    sync do
      if conn = available
        @allocated[thread] = conn
      end
    end
  end
  
  # Returns an available connection to the given server. If no connection is
  # available, tries to create a new connection. The calling code should already
  # have the mutex before calling this.
  def available
    @available_connections.pop || make_new(DEFAULT_SERVER)
  end

  # Alias the default make_new method, so subclasses can call it directly.
  alias default_make_new make_new
  
  # Creates a new connection to the given server if the size of the pool for
  # the server is less than the maximum size of the pool. The calling code
  # should already have the mutex before calling this.
  def make_new(server)
    if (n = size) >= @max_size
      @allocated.keys.each{|t| release(t) unless t.alive?}
      n = nil
    end
    super if (n || size) < @max_size
  end
  
  # Returns the connection owned by the supplied thread for the given server,
  # if any. The calling code should NOT already have the mutex before calling this.
  def owned_connection(thread)
    sync{@allocated[thread]}
  end
  
  # Releases the connection assigned to the supplied thread and server. If the
  # server or connection given is scheduled for disconnection, remove the
  # connection instead of releasing it back to the pool.
  # The calling code should already have the mutex before calling this.
  def release(thread)
    @available_connections << @allocated.delete(thread)
  end

  # Yield to the block while inside the mutex. The calling code should NOT
  # already have the mutex before calling this.
  def sync
    @mutex.synchronize{yield}
  end
  
  CONNECTION_POOL_MAP[[false, false]] = self
end
