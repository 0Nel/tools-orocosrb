require 'utilrb/pkgconfig'
require 'orogen'
require 'fcntl'

module Orocos
    # The working directory that should be used by default in Orocos.run
    def self.default_working_directory
        @default_working_directory || Dir.pwd
    end

    # Resets the working directory that should be used by default in Orocos.run
    # to its default, that is the current directory at the time where Orocos.run
    # is called is used.
    def self.reset_working_directory
        @default_working_directory = nil
    end

    # Sets the working directory that should be used by default in Orocos.run.
    # By default, the current directory at the time where Orocos.run is called
    # is used.
    # 
    # Use #reset_working_directory to use the default of using the current
    # directory.
    def self.default_working_directory=(value)
        value = File.expand_path(value)
        if !File.directory?(value)
            raise ArgumentError, "#{value} is not an existing directory"
        end
        @default_working_directory = value
    end

    # The default commandline arguments that will be passed by default in Orocos.run
    def self.default_cmdline_arguments
	@default_cmdline_arguments || {}
    end

    # Resets the default arguments that should be used by default in Orocos.run
    # which is the default setting of the underlying oroGen components
    def self.reset_default_cmdline_arguments
	@default_cmdline_arguments = {}
    end

    # Sets the default commandline arguments that will be passed by default in Orocos.run
    #
    # Use #reset_default_arguments to use the default of the underlying oroGen components
    def self.default_cmdline_arguments=(value)
	if not default_cmdline_arguments.kind_of?(Hash)
	    raise ArgumentError, "Orocos::default_cmdline_arguments expects to be set as hash"
	end
	@default_cmdline_arguments = value
    end

    def self.tracing?
        !!@tracing_enabled
    end

    def self.tracing=(flag)
        @tracing_enabled = flag
    end

    def self.tracing_library_path
        File.join(Utilrb::PkgConfig.new("orocos-rtt-#{Orocos.orocos_target}").libdir, "liborocos-rtt-traces-#{Orocos.orocos_target}.so")
    end

    # call-seq:
    #   Orocos.run('mod1', 'mod2')
    #   Orocos.run('mod1', 'mod2', :wait => false, :output => '%m-%p.log')
    #   Orocos.run('mod1', 'mod2', :wait => false, :output => '%m-%p.log') do |mod1, mod2|
    #   end
    #
    # Valid options are:
    # wait::
    #   wait that number of seconds (can be floating-point) for the
    #   processes to be ready. If it did not start into the provided
    #   timeout, an Orocos::NotFound exception raised.
    # output::
    #   redirect the process output to the given file. The %m and %p
    #   patterns will be replaced by respectively the name and the PID of
    #   each process.
    # valgrind::
    #   start some or all the processes under valgrind. It can either be an
    #   array of process names (e.g. :valgrind => ['p1', 'p2']) or 'true'.
    #   In the first case, the listed processes will be added to the list of
    #   processes to start (if they are not already in it) and will be
    #   started under valgrind. In the second case, all processes are
    #   started under valgrind.
    # valgrind_options::
    #   an array of options that should be passed to valgrind, e.g.
    #
    #     :valgrind_options => ["--track-origins=yes"]
    # cmdline_args::
    #   When command line arguments are available to deployments, they can be 
    #   set using the following option:
    #      :cmdline_args => { "sd-domain" => '_robot._tcp', "prefix" => "test" }
    #   This will be mapped to '--sd-domain=_robot._tcp --prefix=test'
    #  
    #   Existing commandline arguments:
    #   --sd-domain  
    #   the service discovery domain in which this process should be published
    #   This is only supported by deployments and orogen if the service_discovery
    #   package has been installed along with orogen
    #   The sd domain is of the format: <name>.<suffix> where the suffix has to 
    #   be one of _tcp or _udp
    #   
    # 
    def self.run(*args, &block)
        Process.run(*args, &block)
    end

    # Deprecated. Use Orocos.run instead.
    def self.spawn(*args, &block)
        STDERR.puts "#{caller(1)}: Orocos.spawn is deprecated, use Orocos.run instead"
        run(*args, &block)
    end

    # Base class for process representation objects
    class ProcessBase
        # The process name
        # @return [String]
        attr_reader :name
        # The deployment oroGen model
        # @return [OroGen::Spec::Deployment]
        attr_reader :model
        # @deprecated
        # For backward compatibility only
        def orogen; model end
        # A set of mappings from task names in the deployment model to the
        # actual name in the running process
        attr_reader :name_mappings
        # The set of [task_name, port_name] that represent the ports being
        # currently logged by this process' default logger
        attr_reader :logged_ports
        # The set of task contexts for this process. This is valid only after
        # the process is actually started
        attr_reader :tasks

        def initialize(name, model)
            @name, @model = name, model
            @name_mappings = Hash.new
            @logged_ports = Set.new
            @tasks = []
        end

        # Sets a batch of name mappings
        # @see map_name
        def name_mappings=(mappings)
            mappings.each do |old, new|
                map_name old, new
            end
        end

        # Require that to rename the task called +old+ in this deployment to
        # +new+ during execution
        # @see name_mappings name_mappings=
        def map_name(old, new)
            name_mappings[old] = new
        end

        # use a mapping if exists 
        def get_mapped_name(name)
            name_mappings[name] || name
        end

        # Returns the name of the tasks that are running in this process
        #
        # See also #each_task
        def task_names
            if !model
                raise Orocos::NotOrogenComponent, "#{name} does not seem to have been generated by orogen"
            end
            model.task_activities.map do |deployed_task|
                name = deployed_task.name
                get_mapped_name(name)
            end
        end

        # Enumerate the TaskContext instances of the tasks that are running in
        # this process.
        #
        # See also #task_names
        def each_task
            return enum_for(:each_task) if !block_given?
            task_names.each do |name|
                yield(task(name))
            end
        end

        # Returns the TaskContext instance for a task that runs in this process,
        # or raises Orocos::NotFound.
        def task(task_name, name_service = Orocos.name_service)
            full_name = "#{name}_#{task_name}"
            if result = tasks.find { |t| t.basename == task_name || t.basename == full_name }
                return result
            end

            result = if task_names.include?(task_name)
                         name_service.get task_name, :process => self
                     elsif task_names.include?(full_name)
                         name_service.get full_name, :process => self
                     else
                         raise Orocos::NotFound, "no task #{task_name} defined on #{name}"
                     end

            @tasks << result
            result
        end

        def register_task(task)
            @tasks.delete_if { |t| t.name == task.name }
            @tasks << task
        end

        # Requires all known ports of +self+ to be logged by the default logger
        def log_all_ports(options = Hash.new)
            @logged_ports |= Orocos.log_all_process_ports(self, options)
        end

        @@logfile_indexes = Hash.new

        # Sets up the default logger of this process
        def setup_default_logger(options = Hash.new)
            options = Kernel.validate_options options,
                :remote => false, :log_dir => Orocos.default_working_directory

            is_remote     = options[:remote]
            log_dir       = options[:log_dir]

            if !(logger = self.default_logger)
                return
            end
            log_file_name = logger.basename[/.*(?=_[L|l]ogger)/] || logger.basename

            index = 0
            if options[:remote]
                index = (@@logfile_indexes[name] ||= -1) + 1
                @@logfile_indexes[name] = index
                logger.file = "#{log_file_name}.#{index}.log"
            else
                while File.file?( logfile = File.join(log_dir, "#{log_file_name}.#{index}.log"))
                    index += 1
                end
                logger.file = logfile 
            end
            logger
        end

        # @return [String] the name of the default logger for this process
        def default_logger_name
            candidates = model.task_activities.
                find_all { |d| d.task_model.name == "logger::Logger" }.
                map { |c| name_mappings[c.name] || c.name }

            if candidates.size > 1
                if t = candidates.find { |c| c.name == "#{process.name}_Logger" }
                    return t.name
                end
            elsif candidates.size == 1
                return candidates.first
            end
        end

        # Overrides the default logger usually autodetected by #default_logger
        attr_writer :default_logger

        # @return [#log,false] the logger object that should be used, by
        #    default, to log data coming out of this process, or false if none
        #    can be found
        def default_logger
            if !@logger.nil?
                return @logger
            end

            if logger_name = default_logger_name
                begin
                    @logger = TaskContext.get logger_name
                rescue Orocos::NotFound
                    Orocos.warn "no default logger defined on #{name}, tried #{logger_name}"
                    @logger = false # use false to mark "can not find"
                end
            else
                if Orocos.warn_for_missing_default_loggers?
                    Orocos.warn "cannot determine the default logger name for process #{name}"
                end
                @logger = false
            end

            @logger
        end

        # Extracts a 'prefix' option from the given options hash, and returns
        # the corresponding name mappings if it is set
        #
        # @return [(Hash<String,String>,Hash)] the first element of the pair are
        #   the name mappings that should be added because of the presence of a
        #   prefix option. The second element is the rest of the options
        def self.resolve_prefix_option(options, model)
            prefix, options = Kernel.filter_options options, :prefix => nil
            name_mappings = Hash.new
            if prefix = prefix[:prefix]
                model.task_activities.each do |act|
                    name_mappings[act.name] = "#{prefix}#{act.name}"
                end
            end
            return name_mappings, options
        end
    end

    # The representation of an Orocos process. It manages
    # starting the process and cleaning up when the process
    # dies.
    class Process < ProcessBase
        # The component PkgConfig instance
        attr_reader :pkg
        # The component process ID
        attr_reader :pid

        # Returns the process that has the given PID
        #
        # @param [Integer] pid the PID whose process we are looking for
        # @return [nil,Process] the process object whose PID matches, or nil
	def self.from_pid(pid)
	    if result = registered_processes[pid]
                return result
            end
	end

        class << self
            # A map of existing running processes
            #
            # @return [{Integer=>Process}] a map from process IDs to the
            #   corresponding Process object
            attr_accessor :registered_processes
        end
        @registered_processes = Hash.new

        # Registers a PID-to-process mapping.
        #
        # This can be called only for running processes
        #
        # @param [Process] process the process that should be registered
        # @return [void]
        # @see deregister each
        def self.register(process)
            if !process.alive?
                raise ArgumentError, "cannot register a non-running process"
            end
            registered_processes[process.pid] = process
            nil
        end

        # Deregisters a process object that was registered with {register}
        #
        # @param [Integer] pid the process PID
        def self.deregister(pid)
            if process = registered_processes.delete(pid)
                process
            else raise ArgumentError, "no process registered for PID #{pid}"
            end
        end

        # Enumerates all registered processes
        #
        # @yieldparam [Process] process the process object
        def self.each(&block)
            registered_processes.each_value(&block)
        end

        # A string describing the host. It can be used to check if two processes
        # are running on the same host
        def host_id
            'localhost'
        end

        # Returns true if the process is located on the same host than the Ruby
        # interpreter
        def on_localhost?
            host_id == 'localhost'
        end

        # Creates a new Process instance which will be able to
        # start and supervise the execution of the given Orocos
        # component
        #
        # @param [String] name the process name
        # @param [OroGen::Spec::Deployment] model the process deployment'
        #
        # @overload initialize(name, model_name = name)
        #   deprecated form
        #   @param [String] name the process name
        #   @param [String] model_name the name of the deployment model
        #
        def initialize(name, model = name)
            model = if model.respond_to?(:to_str)
                        Orocos.default_loader.deployment_model_from_name(model)
                    else model
                    end
            @pkg = Orocos.default_pkgconfig_loader.available_deployments[model.name]
            super(name, model)
        end

        # Waits until the process dies
        #
        # This is valid only if the module has been started
        # under rOrocos supervision, using #spawn
        def join
            return unless alive?

	    begin
		::Process.waitpid(pid)
                exit_status = $?
                dead!(exit_status)
	    rescue Errno::ECHILD
	    end
        end
        
        # True if the process is running
        def alive?; !!@pid end
        # True if the process is running
        def running?; alive? end

        # Called externally to announce a component dead.
	def dead!(exit_status) # :nodoc:
            exit_status = (@exit_status ||= exit_status)
            if !exit_status
                Orocos.info "deployment #{name} exited, exit status unknown"
            elsif exit_status.success?
                Orocos.info "deployment #{name} exited normally"
            elsif exit_status.signaled?
                if @expected_exit == exit_status.termsig
                    Orocos.info "deployment #{name} terminated with signal #{exit_status.termsig}"
                elsif @expected_exit
                    Orocos.info "deployment #{name} terminated with signal #{exit_status.termsig} but #{@expected_exit} was expected"
                else
                    Orocos.error "deployment #{name} unexpectedly terminated with signal #{exit_status.termsig}"
                    Orocos.error "This is normally a fault inside the component, not caused by the framework."
                    Orocos.error "Try to run your component within gdb or valgrind with"
                    Orocos.error "  Orocos.run 'component', :gdb=>true"
                    Orocos.error "  Orocos.run 'component', :valgrind=>true"
                    Orocos.error "Make also sure that your component is installed by running 'amake' in it"
                end
            else
                Orocos.warn "deployment #{name} terminated with code #{exit_status.to_i}"
            end

            pid, @pid = @pid, nil
            Process.deregister(pid)

            # Force unregistering the task contexts from CORBA naming
            # service
            # task_names.each do |name|
            #     puts "deregistering #{name}"
            #     Orocos::CORBA.unregister(name)
            # end
	end

	@@logfile_indexes = Hash.new

        # Converts the options given to Orocos.run in a more normalized format
        #
        # It returns a triple (deployments, models, options) where
        #
        # * \c deployments is a map from a deployment name to a prefix that should
        #   be used to run this deployment. Prefixes are prepended to all task
        #   names in the deployment. It is set to nil if there are no prefix.
        # * \c models is a mapping from a oroGen model name to a name. It
        #   requests to start the default deployment for the model_name, using
        #   \c name as the task name
        # * options are options that should be passed to #spawn
        #
        # For instance, in
        #
        #   Orocos.run 'xsens', 'xsens_imu::Task' => 'imu', :valgrind => true
        #
        # One deployment called 'xsens' should be called with no prefix, the
        # default deployment for xsens_imu::Task should be started and the
        # corresponding task be renamed to 'imu' and all deployments should be
        # started with the :valgrind => true option. Therefore, the parsed
        # options would be
        #
        #   deployments = { 'xsens' => nil }
        #   models = { 'xsens_imu::Task' => 'imu' }
        #   options = { valgrind => true }
	#
	# In case multiple instances of a single model need to be started, the
	# names can be given as an Array. E.g. 
	# 
        #   Orocos.run 'xsens_imu::Task' => ['imu1', 'imu2']
        #   
        def self.partition_run_options(*names)
            options = names.last.kind_of?(Hash) ? names.pop : Hash.new
            options, mapped_names = filter_options options,
                :wait => nil, :output => nil, :working_directory => Orocos.default_working_directory,
                :gdb => false, :gdb_options => [],
                :valgrind => false, :valgrind_options => [],
                :cmdline_args => Orocos.default_cmdline_arguments,
                :oro_logfile => nil, :tracing => Orocos.tracing?,
                :loader => Orocos.default_loader,
                :log_level => nil

            loader = options[:loader]
            deployments, models = Hash.new, Hash.new
            names.each { |n| mapped_names[n] = nil }
            mapped_names.each do |object, new_name|
                # If given a name, resolve to the corresponding oroGen spec
                # object
                if object.respond_to?(:to_str) || object.respond_to?(:to_sym)
                    object = object.to_s
                    begin
                        object = loader.task_model_from_name(object)
                    rescue OroGen::NotFound
                        begin
                            object = loader.deployment_model_from_name(object)
                        rescue OroGen::NotFound
                            raise ArgumentError, "#{object} is neither a task model nor a deployment name"
                        end
                    end
                end

                case object
                when OroGen::Spec::TaskContext
                    if !new_name
                        raise ArgumentError, "you must provide a task name when starting a component by type, as e.g. Orocos.run 'xsens_imu::Task' => 'xsens'"
                    end
                    models[object] = new_name
                when OroGen::Spec::Deployment
                    deployments[object] = (new_name if new_name)
                else raise ArgumentError, "expected a task context model or a deployment model, got #{object}"
                end
            end
            return deployments, models, options
        end

        #
        # parse the options passed to run, 
        # and return a list of processes and their individual runtime options.
        #
        def self.parse_run_options(*names)
            deployments, models, options = partition_run_options(*names)
            options, process_options = Kernel.filter_options options, :wait => nil

            if options[:wait].nil?
                options[:wait] =
                    if options[:valgrind] then 60
                    elsif options[:gdb] then 600
                    else 20
                    end
            end

            all_deployments = deployments.keys.map(&:name) + models.values
            valgrind = parse_cmdline_wrapper_option(
                'valgrind', process_options[:valgrind], process_options[:valgrind_options],
                all_deployments)
            gdb = parse_cmdline_wrapper_option(
                'gdbserver', process_options[:gdb], process_options[:gdb_options],
                all_deployments)
            log_level = parse_log_level_option(
                process_options[:log_level], 
                all_deployments)

            name_mappings = resolve_name_mappings(deployments, models)
            processes = name_mappings.map do |deployment_name, mappings, name|
                output = if process_options[:output]
                             process_options[:output].gsub '%m', name
                         end

                spawn_options = Hash[
                    :working_directory => process_options[:working_directory],
                    :output => output,
                    :valgrind => valgrind[name],
                    :gdb => gdb[name],
                    :cmdline_args => process_options[:cmdline_args],
                    :wait => false,
                    :log_level => log_level[name],
                    :oro_logfile => process_options[:oro_logfile]]
                [deployment_name, mappings, name, spawn_options]
            end
            return processes, options
        end

        #
        # log level options can either be a hash specifying an option
        # per deployment, or providing one log_level for all deployments
        #
        def self.parse_log_level_option( options, all_deployments )
            if !options.respond_to?(:to_hash)
                all_deployments.inject(Hash.new) { |h, name| h[name] = options; h }
            else
                options
            end
        end

        def self.parse_cmdline_wrapper_option(cmd, deployments, options, all_deployments)
            if !deployments
                return Hash.new
            end

            if !system("which #{cmd}")
                raise "'#{cmd}' option is specified, but #{cmd} seems not to be installed"
            end

            if !deployments.respond_to?(:to_hash)
                if deployments.respond_to?(:to_str)
                    deployments = [deployments]
                elsif !deployments.respond_to?(:to_ary)
                    deployments = all_deployments
                end

                deployments.inject(Hash.new) { |h, name| h[name] = options; h }
            else
                deployments
            end
        end
        
        def self.resolve_name_mappings(deployments, models)
            processes = []
            processes += deployments.map do |deployment, prefix|
                mapped_name   = deployment.name
                name_mappings = Hash.new
                if prefix
                    name_mappings, _ = ProcessBase.resolve_prefix_option(
                        Hash[:prefix => prefix],
                        deployment)
                    mapped_name = "#{prefix}#{deployment.name}"
                end

                [deployment.name, name_mappings, mapped_name]
            end
            models.each do |model, desired_names|
                desired_names = [desired_names] unless desired_names.kind_of? Array 
                desired_names.each do |desired_name|
                    process_name = OroGen::Spec::Project.default_deployment_name(model.name)
                    name_mappings = Hash[
                        process_name => desired_name,
                        "#{process_name}_Logger" => "#{desired_name}_Logger"]

                    processes << [process_name, name_mappings, desired_name]
                end
            end
            processes
        end
        
        # Do not call directly
        # Use Orocos.run instead
        #
        def self.run(*names)
            if !Orocos.initialized?
                #try to initialize orocos before bothering the user
                Orocos.initialize
            end
            if !Orocos::CORBA.initialized?
                raise "CORBA layer is not initialized! There might be problem with the installation."
            end

            begin
                process_specs, options = parse_run_options(*names)

                # Then spawn them, but without waiting for them
                processes = process_specs.map do |deployment_name, name_mappings, name, spawn_options|
                    p = Process.new(name, deployment_name)
                    name_mappings.each do |old, new|
                        p.map_name old, new
                    end
                    p.spawn(spawn_options)
                    p
                end

                # Finally, if the user required it, wait for the processes to run
                if options[:wait]
                    timeout = if options[:wait].kind_of?(Numeric)
                                  options[:wait]
                              else Float::INFINITY
                              end
                    processes.each { |p| p.wait_running(timeout) }
                end

            rescue Exception => original_error
                # Kill the processes that are already running
                if processes
		    begin
			kill(processes.map { |p| p if p.running? }.compact)
		    rescue Exception => e
			Orocos.warn "failed to kill the started processes, you will have to kill them yourself"
			Orocos.warn e.message
			e.backtrace.each do |l|
			    Orocos.warn "  #{l}"
			end
			raise original_error
		    end
                end
                raise
            end

            if block_given?
                Orocos.guard(*processes) do
                    yield(*processes)
                end
            else
                processes
            end
        end
        
        # Kills the given processes. If +wait+ is true, will also wait for the
        # processes to be destroyed.
        def self.kill(processes, wait = true)
            processes.each { |p| p.kill if p.running? }
            if wait
                processes.each { |p| p.join }
            end
        end

        def self.gdb_base_port=(port)
            @@gdb_port = port - 1
        end

        @@gdb_port = 30000
        def self.allocate_gdb_port
            @@gdb_port += 1
        end

        # Spawns this process
        #
        # Valid options:
        # output::
        #   if non-nil, the process output is redirected towards that
        #   file. Special patterns %m and %p are replaced respectively by the
        #   process name and the process PID value.
        # valgrind::
        #   if true, the process is started under valgrind. If :output is set
        #   as well, valgrind's output is redirected towards the value of output
        #   with a .valgrind extension added.
        def spawn(options = Hash.new)
	    raise "#{name} is already running" if alive?
	    Orocos.info "starting deployment #{name}"

            options = Kernel.validate_options options, :output => nil,
                :gdb => nil, :valgrind => nil,
                :log_level => nil,
                :working_directory => nil,
                :cmdline_args => Hash.new, :wait => nil,
                :oro_logfile => "orocos.%m-%p.txt",
                :prefix => nil, :tracing => Orocos.tracing?,
                :name_service => Orocos::CORBA.name_service

            name_service = options[:name_service]

            # Setup mapping for prefixed tasks in Process class
            prefix_mappings, options = ProcessBase.resolve_prefix_option(options, model)
            name_mappings = prefix_mappings.merge(self.name_mappings)
            self.name_mappings = name_mappings

            # If possible, check that we won't clash with an already running
            # process
            task_names.each do |name|
                if name_service.task_reachable?(name)
                    raise ArgumentError, "there is already a running task called #{name}, are you starting the same component twice ?"
                end
            end

            if !options.has_key?(:wait)
                if options[:valgrind]
                    options[:wait] = 60
                elsif options[:gdb]
                    options[:wait] = 600
                else
                    options[:wait] = 20
                end
            end

            cmdline_args = options[:cmdline_args].dup
            cmdline_args[:rename] ||= []
            name_mappings.each do |old, new|
                cmdline_args[:rename].push "#{old}:#{new}"
            end

            output   = options[:output]
            oro_logfile = options[:oro_logfile]

            if options[:valgrind]
                cmdline_wrapper = 'valgrind'
                cmdline_wrapper_options =
                    if options[:valgrind].respond_to?(:to_ary)
                        options[:valgrind]
                    else []
                    end
            elsif options[:gdb]
                cmdline_wrapper = 'gdbserver'
                cmdline_wrapper_options =
                    if options[:gdb].respond_to?(:to_ary)
                        options[:gdb]
                    else []
                    end
                gdb_port = Process.allocate_gdb_port
                cmdline_wrapper_options << "localhost:#{gdb_port}"
            end

            workdir  = options[:working_directory]

	    if !CORBA.name_service.ip.empty?
		ENV['ORBInitRef'] = "NameService=corbaname::#{CORBA.name_service.ip}"
	    end

            module_bin = pkg.binfile
            if !module_bin # assume an older orogen version
                module_bin = "#{pkg.exec_prefix}/bin/#{name}"
            end
            cmdline = [module_bin]
		    
	    read, write = IO.pipe
	    @pid = fork do 
                if options[:tracing]
                    ENV['LD_PRELOAD'] = Orocos.tracing_library_path
                end

                if options[:log_level]
                    if [:debug, :info, :warn, :error, :fatal].include? options[:log_level]
                        ENV['BASE_LOG_LEVEL'] = options[:log_level].to_s.upcase
                    else
                        Orocos.warn "'#{options[:log_level]}' is not a valid log level."
                    end
                end

                pid = ::Process.pid
                real_name = get_mapped_name(name)

		if output && output.respond_to?(:to_str)
		    output_file_name = output.
			gsub('%m', real_name).
			gsub('%p', pid.to_s)
                    if workdir
                        output_file_name = File.expand_path(output_file_name, workdir)
                    end

                    output = File.open(output_file_name, 'a')
		end

                if oro_logfile
                    oro_logfile = oro_logfile.
                        gsub('%m', real_name).
                        gsub('%p', pid.to_s)
                    if workdir
                        oro_logfile = File.expand_path(oro_logfile, workdir)
                    end
                    ENV['ORO_LOGFILE'] = oro_logfile
                else
                    ENV['ORO_LOGFILE'] = "/dev/null"
                end

		if output
		    STDERR.reopen(output)
		    STDOUT.reopen(output)
		end

                if output_file_name && options[:valgrind]
                    cmdline.unshift "--log-file=#{output_file_name}.valgrind"
                end

                if cmdline_wrapper
                    cmdline = cmdline_wrapper_options + cmdline
                    cmdline.unshift cmdline_wrapper
                end
                
                # Command line arguments have to be of type --<option>=<value>
                # or if <value> is nil a valueless option, i.e. --<option>
                if cmdline_args
                    cmdline_args.each do |option, value|
                        if value
                           if value.respond_to?(:to_ary)
                                value.each do |v|
                                    cmdline.push "--#{option}=#{v}"
                                end
                           else
                               cmdline.push "--#{option}=#{value}"
                           end
                        else
                            cmdline.push "--#{option}"
                        end
                    end
                end
		read.close
		write.fcntl(Fcntl::F_SETFD, 1)
		::Process.setpgrp
                begin
                    if workdir
                        Dir.chdir(workdir)
                    end
                    exec(*cmdline)
                rescue Exception
                    write.write("FAILED")
                end
	    end
            Process.register(self)

	    write.close
	    if read.read == "FAILED"
		raise "cannot start #{name}"
	    end

            if options[:gdb]
                Orocos.warn "process #{name} has been started under gdbserver, port=#{gdb_port}. The components will not be functional until you attach a GDB to the started server"
            end

            if options[:wait]
                timeout = if options[:wait].kind_of?(Numeric)
                              options[:wait]
                          elsif options[:wait]
                              Float::INFINITY
                          end
                wait_running(timeout, name_service)
            end
        end

	# Wait for a process (TaskContext by default) to become reachable
	# To determine whether the process is reachable a block can be given taken the
	# process object as argument
	# If no block is given the default implementation applies which relies on
	# TaskContext#reachable?
        def self.wait_running(process, timeout = nil, name_service = Orocos::CORBA.name_service, &block)
	    if timeout == 0
		return nil if !process.alive?

                # Use custom block to check if the process is reachable
                if block_given?
                    block.call(process)
                else
                    # Get any task name from that specific deployment, and check we
                    # can access it. If there is none
                    all_reachable = process.task_names.all? do |task_name|
                        if name_service.task_reachable?(task_name)
                            Orocos.debug "#{task_name} is reachable"
                            true
                        else
                            Orocos.debug "could not access #{task_name}, #{name} is not running yet ..."
                            false
                        end
                    end
                    if all_reachable
                        Orocos.info "all tasks of #{process.name} are reachable, assuming it is up and running"
                    end
                    all_reachable
                end
	    else
                start_time = Time.now
                got_alive = process.alive?
                while true
		    if wait_running(process, 0, name_service, &block)
			break
                    elsif not timeout
                        break
                    elsif timeout < Time.now - start_time
                        break
                    end

                    if got_alive && !process.alive?
                        raise Orocos::NotFound, "#{process.name} was started but crashed"
                    end
                    sleep 0.1
                end

                if process.alive?
                    return true
                else
                    raise Orocos::NotFound, "cannot get a running #{process.name} module"
                end
	    end
	end

        # Wait for the module to be started. If timeout is 0, the function
        # returns immediately, with a false return value if the module is not
        # started yet and a true return value if it is started.
        #
        # Otherwise, it waits for the process to start for the specified amount
        # of seconds. It will throw Orocos::NotFound if the process was not
        # started within that time.
        #
        # If timeout is nil, the method will wait indefinitely
        def wait_running(timeout = nil, name_service = Orocos::CORBA.name_service)
            Process.wait_running(self, timeout, name_service)
	end

        SIGNAL_NUMBERS = {
            'SIGABRT' => 1,
            'SIGINT' => 2,
            'SIGKILL' => 9,
            'SIGSEGV' => 11
        }

        # Tries to stop and cleanup the provided task. Returns true if it was
        # successful, and false otherwise
        def self.try_task_cleanup(task)
            begin
                task.stop(false)
                if task.model && task.model.needs_configuration?
                    task.cleanup(false)
                end
            rescue StateTransitionFailed
            end

            task.each_port do |port|
                port.disconnect_all
            end

            true

        rescue Exception => e
            Orocos.warn "clean shutdown of #{task.name} failed: #{e.message}"
            e.backtrace.each do |line|
                Orocos.warn line
            end
            false
        end

        # Kills the process either cleanly by requesting a shutdown if signal ==
        # nil, or forcefully by using UNIX signals if signal is a signal name.
        def kill(wait = true, signal = nil)
            tpid = pid
            return if !tpid # already dead

            # Stop all tasks and disconnect the ports
            if !signal
                clean_shutdown = true
                begin
                    each_task do |task|
                        if !self.class.try_task_cleanup(task)
                            clean_shutdown = false
                            break
                        end
                    end
                rescue Orocos::NotFound, Orocos::NoModel
                    # We're probably still starting the process. Just go on and
                    # signal it
                    clean_shutdown = false
                end
                if !clean_shutdown
                    Orocos.warn "clean shutdown of process #{name} failed"
                end
            end

            expected_exit = nil
            if clean_shutdown
                expected_exit = signal = SIGNAL_NUMBERS['SIGINT']
	    else
                signal = SIGNAL_NUMBERS['SIGINT']
            end

            if signal 
                if !expected_exit
                    Orocos.warn "sending #{signal} to #{name}"
                end

                if signal.respond_to?(:to_str) && signal !~ /^SIG/
                    signal = "SIG#{signal}"
                end

                expected_exit ||=
                    if signal.kind_of?(Integer) then signal
                    else SIGNAL_NUMBERS[signal] || signal
                    end

                @expected_exit = expected_exit
                begin
                    ::Process.kill(signal, tpid)
                rescue Errno::ESRCH
                    # Already exited
                    return
                end
            end

            if wait
                join
                if @exit_status && @exit_status.signaled?
                    if !expected_exit
                        Orocos.warn "#{name} unexpectedly exited with signal #{@exit_status.termsig}"
                    elsif @exit_status.termsig != expected_exit
                        Orocos.warn "#{name} was expected to quit with signal #{expected_exit} but terminated with signal #{@exit_status.termsig}"
                    end
                end
            end
        end
    end

    # Enumerates the Orocos::Process objects that are currently available in
    # this Ruby instance
    def self.each_process(&block)
        Process.each(&block)
    end

    # call-seq:
    #   guard { }
    #
    # All processes started in the provided block will be automatically killed
    def self.guard(*processes_or_tasks)
        yield

    rescue Interrupt
    rescue Exception => e
	Orocos.warn "killing running task contexts and deployments because of unhandled exception"
	Orocos.warn "  #{e.backtrace[0]}: #{e.message}"
	e.backtrace[1..-1].each do |line|
	    Orocos.warn "    #{line}"
	end
        raise

    ensure
        processes, tasks = processes_or_tasks.partition do |obj|
            obj.kind_of?(Orocos::Process)
        end

        if processes.empty?
            processes = each_process.to_a
        end
        if !tasks.empty?
            processes.each do |p|
                tasks -= p.each_task.to_a
            end
        end

        # NOTE: Process#kill stops all the tasks from the process first, so
        # that's fine.
        tasks.each do |t|
            Orocos.info "guard: stopping task #{t.name}"
            Orocos::Process.try_task_cleanup(t)
        end
        processes.each do |p|
            if p.running?
                Orocos.info "guard: stopping process #{p.name}"
                p.kill(false) 
            end
        end
        processes.each do |p|
            if p.running?
                Orocos.info "guard: joining process #{p.name}"
                p.join
            end
        end
    end
end

