
module Orocos
    module Log
	# Exception if a port can not be initialized
	class InitializePortError < RuntimeError
	    def initialize( message, name )
		super( message )
		@port_name = name
	    end

	    attr_reader :port_name
	end

        # Simulates an output port based on log files.
        # It has the same behavior like an OutputReader
        class OutputReader
            #Handle to the port the reader is reading from
            attr_reader :port

            #filter for log data 
            #the filter is applied during read
            #the buffer is not effected 
            attr_accessor :filter

            #Creates a new OutputReader
            #
            #port => handle to the port the reader shall read from
            #policy => policy for reading data 
            #
            #see project orocos.rb for more information
            def initialize(port,policy=default_policy)
                policy = default_policy if !policy
                @port = port
                @buffer = Array.new
                @filter, policy = Kernel.filter_options(policy,[:filter])
                @filter = @filter[:filter]
                policy = Orocos::Port.prepare_policy(policy)
                @policy_type = policy[:type]
                @buffer_size = policy[:size]
                @last_update = Time.now
            end

            #This method is called each time new data are availabe.
            def update(data) 
                if @policy_type == :buffer
                    @buffer.shift if @buffer.size == @buffer_size
                    @buffer << data
                end
            end

            #Clears the buffer of the reader.
            def clear_buffer 
                @buffer.clear
            end

            #Reads data from the associated port.
            def read(sample =nil)
                if @policy_type == :data
                  @last_update = port.last_update
                  return @filter.call(port.read) if @filter
                  return port.read
                elsif @policy_type == :buffer
                  sample = @buffer.shift
                  if sample
                    return @filter.call(sample) if @filter
                    return sample
                  else
                    @last_update = port.last_update
                    return nil
                  end
                else
                    raise "Port policy #{@policy_type} is not supported."
                end
            end
           
            #Reads data from the associated port.
            #Return nil if no new data are available
            def read_new(sample = nil)
              return nil if @last_update == port.last_update 
              read
            end

            def new_sample
                @port.new_sample
            end
        end

        #Simulates a port based on log files
        #It has the same behavior like Orocos::OutputPorts
        class OutputPort

            #true -->  this port shall be replayed even if there are no connections
            attr_accessor :tracked         

            #name of the recorded port
            attr_reader :name 

            #name of the type as Typelib::Type object           
            attr_reader :type          

            #name of the type as it is used in ruby
            attr_reader :type_name      

            #connections between this port and InputPort ports that support a writer
            attr_reader :connections    

            #dedicated stream for simulating the port
            attr_reader :stream         

            #parent log task
            attr_reader :task          

            #number of readers which are using the port
            attr_reader :readers        

            #returns true if replay has started
            attr_reader :replay

            #returns the system time when the port was updated with new data
            attr_reader :last_update

            #filter for log data
            #the filter is applied before all connections and readers are updated 
            #if you want to apply a filter only for one connection or one reader do not set 
            #the filter here.
            #the filter must be a proc, lambda, method or object with a function named call.
            #the signature must be:
            #new_massage call(old_message)
            attr_accessor :filter

            class << self
              attr_accessor :default_policy
            end
            self.default_policy = Hash.new
            self.default_policy[:type] = :data

            #Defines a connection which is set through connect_to
            class Connection #:nodoc:
                attr_accessor :port,:writer,:filter
                def initialize(port,policy=Hash.new)
                    @port = port
                    policy =  OutputPort::default_policy if !policy
                    @filter, policy = Kernel.filter_options(policy,[:filter])
                    @filter = @filter[:filter]
                    @writer = port.writer(policy)
                end

                def update(data)
                  if @filter 
                    @writer.write(@filter.call data)
                  else
                    @writer.write(data)
                  end
                end
            end
            
            #Defines a connection which is set through connect_to
            class CodeBlockConnection #:nodoc:
                def initialize(port_name,code_block)
                    @code_block = code_block
                    @port_name = port_name
                end
                def update(data)
                    @code_block.call data,@port_name
                end
            end

            #if force_local? returns true this port will never be proxied by an orogen port proxy
            def force_local?
                return true
            end

            def to_orocos_port
                self
            end

            def filter=(filter)
              @filter=filter
              self.tracked=true
            end

            #Pretty print for OutputPort.
	    def pretty_print(pp)
                pp.text "#{task.name}.#{name}"
		pp.nest(2) do
		    pp.breakable
		    pp.text "tracked = #{@tracked}"
		    pp.breakable
		    pp.text "readers = #{@readers.size}"
		    pp.breakable
		    pp.text "filtered = #{(@filter!=nil).to_s}"
		    @connections.each do |connection|
			pp.breakable
                        if connection.is_a?(OutputPort::Connection)
                          pp.text "connected to #{connection.port.task.name}.#{connection.port.name} (filtered = #{(connection.filter!=nil).to_s})"
                        end
                        if connection.is_a?(OutputPort::CodeBlockConnection)
                          pp.text "connected to code block"
                        end
		    end
		end
            end

            #returns the metadata associated with the underlying stream
            def metadata
                stream.metadata
            end

            # Give the full name for this port. It is the stream name.
            def full_name
                stream.name
            end

            #Creates a new object of OutputPort
            #
            #task => simulated task for which the port shall be created
            #stream => stream from which the port shall be created 
            def initialize(task,stream)
                raise "Cannot create OutputPort out of #{stream.class}" if !stream.instance_of?(Pocolog::DataStream)
                @stream = stream
                @name = stream.name.to_s.match(/\.(.*$)/)
		if @name == nil
		    @name = "#{stream.name.to_s}"
		    Log.warn "Stream name (#{stream.name}) does not follow the convention TASKNAME.PORTNAME, assuming as PORTNAME \"#{@name}\""
		else	
		    @name = @name[1]
		end
		begin
		    @type = stream.type
		rescue Exception => e
		    raise InitializePortError.new( e.message, @name )
		end
                @type_name = stream.typename
                @task = task
                @connections = Array.new
                @current_data = nil
                @tracked = false
                @readers = Array.new
                @replay = false
                @last_update = Time.now
            end

            #Creates a new reader for the port.
            def reader(policy = OutputPort::default_policy,&block)
                policy[:filter] = block if block
                self.tracked = true
                new_reader = OutputReader.new(self,policy)
                @readers << new_reader
                return new_reader
            end

            #Returns true if the port has at least one connection or 
            #tracked is set to true.
            def used?
                return @tracked
            end

            #Returns the current sample data.
            def read()
                raise "Port #{@name} is not replayed. Set tracked to true or use a port reader!" unless used? 
                return yield @current_data if block_given?
                return @current_data
            end

            #If set to true the port is replayed.  
            def tracked=(value)
                raise "can not track unused port #{stream.name} after the replay has started" if !used? && replay
                @tracked = value
            end

            #Register InputPort which is updated each time write is called
            def connect_to(port=nil,policy = OutputPort::default_policy,&block)
                port = port.to_orocos_port if port.respond_to?(:to_orocos_port)
                self.tracked = true
                policy[:filter] = block if block
                if !port 
                  raise "Cannot set up connection no code block or port is given" unless block
                  @connections << CodeBlockConnection.new(@name,block)
                else
                  raise "Cannot connect to #{port.class}" if(!port.instance_of?(Orocos::InputPort))
                  @connections << Connection.new(port,policy)
                  Log.info "setting connection: #{task.name}.#{name} --> #{port.task.name}.#{port.name}"
                end
            end

            #Feeds data to the connected ports and readers
            def write(data)
                @last_update = Time.now
                @current_data = @filter ? @filter.call(data) : data
                @connections.each do |connection|
                    connection.update(@current_data)
                end
                @readers.each do |reader|
                    reader.update(@current_data)
                end
            end

            #Disconnects all ports and deletes all readers 
            def disconnect_all
                @connections.clear
                @readers.clear
            end

            #Returns a new sample object
            def new_sample
                @type.new
            end

            #Clears all reader buffers 
            def clear_reader_buffers
                @readers.each do |reader|
                    reader.clear_buffer
                end
            end

            #Is called from align.
            #If replay is set to true, the log file streams are aligned and no more
            #streams can be added.
            def set_replay
                @replay = true
            end

            #Returns the number of samples for the port.
            def number_of_samples
                return @stream.size
            end
        end
        
        #Simulated Property based on a configuration log file
        #It is automatically replayed if at least one OutputPort of the task is replayed
        class Property
            #true -->  this property shall be replayed
            attr_accessor :tracked         
            # The underlying TaskContext instance
            attr_reader :task
            # The property/attribute name
            attr_reader :name
            # The attribute type, as a subclass of Typelib::Type
            attr_reader :type
            #dedicated stream for simulating the port
            attr_reader :stream         


            def initialize(task, stream)
                raise "Cannot create Property out of #{stream.class}" if !stream.instance_of?(Pocolog::DataStream)
                @stream = stream
                @name = stream.name.to_s.match(/\.(.*$)/)
                raise 'Stream name does not follow the convention TASKNAME.PROPERTYNAME' if @name == nil
                @name = @name[1]
                @type = stream.type
                @task = task
                @current_value = nil
                @orocos_type_name = stream.typename
            end

            # Read the current value of the property/attribute
            def read
                @current_value
            end

            # Sets a new value for the property/attribute
            def write(value)
                @current_value = value
            end

            def new_sample
                type.new
            end

            #Returns the number of samples for the property.
            def number_of_samples
                return @stream.size
            end

            # Give the full name for this property. It is the stream name.
            def full_name
                stream.name
            end

            def pretty_print(pp) # :nodoc:
                pp.text "property #{name} (#{type.name})"
            end

            #returns the metadata associated with the underlying stream
            def metadata
                stream.metadata
            end
        end


        #Simulates task based on a log file.
        #Each stream is modeled as one OutputPort which supports the connect_to method
        class TaskContext
            attr_accessor :ports               #all simulated ports
            attr_accessor :properties          #all simulated properties
            attr_reader :file_path             #path of the dedicated log file
            attr_reader :file_path_config      #path of the dedicated log configuration file
            attr_reader :name
            attr_reader :state

            #Creates a new instance of TaskContext.
            #
            #* task_name => name of the task
            #* file_path => path of the log file
            def initialize(task_name,file_path,file_path_config)
                @ports = Hash.new
		@invalid_ports = Hash.new # ports that could not be loaded
                @properties = Hash.new
                @file_path = file_path
                @name = task_name
                @state = :replay
                @file_path_config = nil
                @file_path_config_reg = file_path_config
            end

            #to be compatible wiht Orocos::TaskContext
            #indecates if the task is replayed
            def running?
                used?
            end

            #to be compatible wiht Orocos::TaskContext
            def reachable?
                true
            end

            #pretty print for TaskContext
	    def pretty_print(pp)
                pp.text "#{name}:"
		pp.nest(2) do
		    pp.breakable
		    pp.text "log file: #{file_path}"
		    pp.breakable
		    pp.text "port(s):"
		    pp.nest(2) do
			@ports.each_value do |port|
			    pp.breakable
			    pp.text port.name
			end
                    end
		    pp.breakable
                    pp.text "property(s):"
		    pp.nest(2) do
			@properties.each_value do |port|
			    pp.breakable
			    pp.text port.name
			end
		    end
		end
            end
    
            #Adds a new property or port to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_stream(file_path,stream)
                if Regexp.new(@file_path_config_reg).match(file_path) || stream.metadata["rock_stream_type"] == "property"
                    log = add_property(file_path,stream)
                else
                    log = add_port(file_path,stream)
                end
                log
            end

            #Adds a new property to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_property(file_path,stream)
                if @file_path_config && !Regexp.new(@file_path_config).match(file_path)
                    raise "You are trying to add properties to the task from different log files #{@file_path}; #{file_path}!!!" if @file_path_config != file_path
                end
                if @file_path == file_path
                    @file_path = nil 
                end
                @file_path_config = file_path

                log_property = Property.new(self,stream)
                raise ArgumentError, "The log file #{file_path} is already loaded" if @properties.has_key?(log_property.name)
                @properties[log_property.name] = log_property
                return log_property
            end

            #Adds a new port to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_port(file_path,stream)
                #overwrite ports if the file is different and newer than the current one 
                if @file_path && @file_path != file_path
                    if File.new(@file_path).ctime < File.new(file_path ).ctime
                        Log.warn "For task #{name} using ports from \"#{file_path}\" instead of \"#{@file_path}\", because the file is more recent."
                        @ports.clear
                        @file_path = file_path
                    else
                        Log.warn "For task #{name} ommiting log file \"#{file_path}\", because it is older than \"#{@file_path}\"."
                        return nil
                    end
                end
                begin
                    log_port = OutputPort.new(self,stream)
                    raise ArgumentError, "The log file #{file_path} is already loaded" if @ports.has_key?(log_port.name)
                    @ports[log_port.name] = log_port
                rescue InitializePortError => error
                    @invalid_ports[error.port_name] = error.message
                    raise error
                end
                log_port
            end

            #TaskContexts do not have attributes. 
            #This is implementd to be compatible with TaskContext.
            def each_attribute
            end

            # Returns true if this task has a Orocos method with the given name.
            # In this case it always returns false because a TaskContext does not have
            # Orocos methods.
            # This is implementd to be compatible with TaskContext.
            def has_method?(name)
                return false;
            end


            # Returns the array of the names of available properties on this task
            # context
            def property_names
                @properties.values
            end

            # Returns the array of the names of available attributes on this task
            # context
            def attribute_names
                Array.new
            end

            # Returns true if +name+ is the name of a property on this task context
            def has_property?(name)
                properties.has_key?(name.to_str)
            end

            # Returns true if this task has a command with the given name.
            # In this case it always returns false because a TaskContext does not have
            # command.
            # This is implementd to be compatible with TaskContext.
            def has_command?(name)
                return false;
            end

            # Returns true if this task has a port with the given name.
            def has_port?(name)
                name = name.to_s
                return @ports.has_key?(name) || @invalid_ports.has_key?(name)
            end

            # Iterates through all simulated properties.
            def each_property(&block)
                @properties.each_value do |property|
                    yield(property) if block_given?
                end
            end

            #Returns the property with the given name.
            #If no port can be found a exception is raised.
            def property(name, verify = true)
                name = name.to_str
                if @properties[name]
                    return @properties[name]
                else
                    raise NotFound, "no property named '#{name}' on log task '#{self.name}'"
                end
            end

            # Iterates through all simulated ports.
            def each_port(&block)
                @ports.each_value do |port|
                    yield(port) if block_given?
                end
            end

            #Returns the port with the given name.
            #If no port can be found a exception is raised.
            def port(name, verify = true)
                name = name.to_str
                if @ports[name]
                    return @ports[name]
		elsif @invalid_ports[name]
		    raise NotFound, "the port named '#{name}' on log task '#{self.name}' could not be loaded: #{@invalid_ports[name]}"
                else
                    raise NotFound, "no port named '#{name}' on log task '#{self.name}'"
                end
            end

            #Returns an array of ports where each port has at least one connection
            #or tracked set to true.
            def used_ports
                ports = Array.new
                @ports.each_value do |port|
                    ports << port if port.used?
                end
                return ports
            end

            #Returns true if the task has used ports
            def used?
              !used_ports.empty?
            end

            #Returns an array of unused ports
            def unused_ports
                ports = Array.new
                @ports.each_value do |port|
                    ports << port if !port.used?
                end
                return ports
            end

            def find_all_ports(type_name, port_name=nil)
                Orocos::TaskContext.find_all_ports(@ports.values, type_name, port_name)
            end
            def find_port(type_name, port_name=nil)
                Orocos::TaskContext.find_port(@ports.values, type_name, port_name)
            end

            #Tries to find a OutputPort for a specefic data type.
            #For port_name Regexp is allowed.
            #If precise is set to true an error will be raised if more
            #than one port is matching type_name and port_name.
            def port_for(type_name, port_name, precise=true)
                Log.warn "#port_for is deprecated. Use either #find_all_ports or #find_port"
                if precise
                    find_port(type_name, port_name)
                else find_all_ports(type_name, port_name)
                end
            end

            #If set to true all ports are replayed 
            #otherwise only ports are replayed which have a reader or
            #a connection to an other port
            def track(value,filter = Hash.new)
                options, filter = Kernel::filter_options(filter,[:ports,:types,:limit])
                raise "Cannot understand filter: #{filter}" unless filter.empty?

                @ports.each_value do |port|
                    if(options.has_key? :ports)
                        next unless port.name =~ options[:ports]
                    end
                    if(options.has_key? :types)
                        next unless port.type_name =~ options[:types]
                    end
                    if(options.has_key? :limit)
                        next unless port.number_of_samples <= options[:limit]
                    end
                    port.tracked = value
                    Log.info "set" + port.stream.name + value.to_s
                end
            end

            #Clears all reader buffers
            def clear_reader_buffers
                @ports.each_value do |port|
                    port.clear_reader_buffers
                end
            end

            #This is used to allow the following syntax
            #task.port_name.connect_to(other_port)
            def method_missing(m, *args,&block) #:nodoc:
                m = m.to_s
                if m =~ /^(\w+)=/
                    name = $1
                    Log.warn "Setting the property #{name} the TaskContext #{@name} is not supported"
                    return
                end
                if has_port?(m) 
                  _port = port(m)
                  _port.filter = block if block         #overwirte filer
                  return _port
                end
                if has_property?(m) 
                   return property(m)
                end
                super(m.to_sym, *args)
            end
        end

    end
end