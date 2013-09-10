require 'forwardable'
require 'delegate'

module Orocos::Async
    class AttributeBaseProxy < ObjectBase
        extend Forwardable
        define_events :change
        attr_reader :last_sample

        methods = Orocos::AttributeBase.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods -= AttributeBaseProxy.instance_methods + [:method_missing,:name]
        methods << :type
        def_delegators :@delegator_obj,*methods

        def initialize(task_proxy,attribute_name,options=Hash.new)
            @type = options.delete(:type) if options.has_key? :type
            @options = options
            super(attribute_name,task_proxy.event_loop)
            @task_proxy = task_proxy
            @last_sample = nil
        end

        def type_name
            type.name
        end

        def type
            @type ||= @delegator_obj.type
        end

        # returns true if the proxy stored the type
        def type?
            !!@type
        end

        # do not emit anything because reachable will be emitted by the delegator_obj
        def reachable!(attribute,options = Hash.new)
            @options = attribute.options
            if @type && @type != attribute.type && @type.name != attribute.orocos_type_name
                raise RuntimeError, "the given type #{@type} for attribute #{attribute.name} differes from the real type name #{attribute.type}"
            end
            @type = attribute.type
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            disable_emitting do
                super(attribute,options)
            end
            proxy_event(@delegator_obj,@delegator_obj.event_names)
        rescue Orocos::NotFound
            unreachable!
        end

        def unreachable!(options=Hash.new)
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            super(options)
        end

        def period
            if @options.has_key? :period
                @options[:period]
            else
                nil
            end
        end

        def period=(period)
            @options[:period] = period
            @delegator_obj.period = period if valid_delegator?
        end

        def add_listener(listener)
            return super unless listener.use_last_value?

            if listener.event == :change
                sample = last_sample
                if sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            end
            super
        end

        def on_change(policy = Hash.new,&block)
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !valid_delegator?
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "ProxyProperty #{full_name} cannot emit :change with different policies."
                           Orocos.warn "The current policy is: #{@options}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @options
                       end
            on_event :change,&block
        end

        private
        def process_event(event_name,*args)
            @last_sample = args.first if event_name == :change
            super
        end

    end

    class PropertyProxy < AttributeBaseProxy
    end

    class AttributeProxy < AttributeBaseProxy
    end

    class PortProxy < ObjectBase
        extend Forwardable
        define_events :data

        methods = Orocos::Port.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods -= PortProxy.instance_methods + [:method_missing,:name]
        methods << :write
        methods << :type
        def_delegators :@delegator_obj,*methods
        
        def initialize(task_proxy,port_name,options=Hash.new)
            super(port_name,task_proxy.event_loop)
            @task_proxy = task_proxy
            @type = options.delete(:type) if options.has_key? :type
            @options = options
            @last_sample = nil
        end

        def type_name
            type.name
        end

        def full_name
            "#{@task_proxy.name}.#{name}"
        end

        def type
            @type ||= @delegator_obj.type
        end

        # returns true if the proxy stored the type
        def type?
            !!@type
        end

        def to_async(options=Hash.new)
            task.to_async(options).port(port.name)
        end

        def to_proxy(options=Hash.new)
            self
        end

        def task
            @task_proxy
        end

        def input?
            if !valid_delegator?
                true
            elsif @delegator_obj.respond_to?(:writer)
                true
            else
                false
            end
        end

        def output?
            if !valid_delegator?
                true
            elsif @delegator_obj.respond_to?(:reader)
                true
            else
                false
            end
        end

        def reachable?
            super && @delegator_obj.reachable?
        end

        # do not emit anything because reachable will be emitted by the delegator_obj
        def reachable!(port,options = Hash.new)
            raise ArgumentError, "port must not be kind of PortProxy" if port.is_a? PortProxy
            if @type && @type != port.type && @type.name != port.orocos_type_name
                raise RuntimeError, "the given type #{@type} for port #{port.full_name} differes from the real type name #{port.type}"
            end

            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            disable_emitting do
                super(port,options)
            end
            proxy_event(@delegator_obj,@delegator_obj.event_names)
            @type = port.type

            #check which port we have
            if !port.respond_to?(:reader) && number_of_listeners(:data) != 0
                raise RuntimeError, "Port #{name} is an input port but callbacks for on_data are registered" 
            end
        rescue Orocos::NotFound
            unreachable!
        end

        def unreachable!(options = Hash.new)
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            super(options)
        end

        # returns a sub port for the given subfield
        def sub_port(subfield)
            raise RuntimeError , "Port #{name} is not an output port" if !output?
            SubPortProxy.new(self,subfield)
        end

        def period
            if @options.has_key? :period
                @options[:period]
            else
                nil
            end
        end

        def period=(period)
            raise RuntimeError, "Port #{name} is not an output port" if !output?
            @options[:period] = period
            @delegator_obj.period = period if valid_delegator?
        end

        def last_sample
            @last_sample
        end

        def add_listener(listener)
            return super unless listener.use_last_value?

            if listener.event == :data
                sample = last_sample
                if sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            end
            super
        end

        def on_data(policy = Hash.new,&block)
            raise RuntimeError , "Port #{name} is not an output port" if !output?
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !valid_delegator?
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "ProxyPort #{full_name} cannot emit :data with different policies."
                           Orocos.warn "The current policy is: #{@options}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @options
                       end
            on_event :data,&block
        end
        
        private
        def process_event(event_name,*args)
            @last_sample = args.first if event_name == :data
            super
        end
    end

    class SubPortProxy < DelegateClass(PortProxy)
        def initialize(port_proxy,subfield = Array.new)
            super(port_proxy)
            @subfield = Array(subfield).map do |field|
                if field.respond_to?(:to_i) && field.to_i.to_s == field
                    field.to_i
                else
                    field
                end
            end
        end

        def to_async(options=Hash.new)
            task.to_async(options).port(port.name,:subfield => @subfield)
        end

        def to_proxy(options=Hash.new)
            self
        end

        def on_data(policy = Hash.new,&block)
            p = proc do |sample|
                block.call subfield(sample,@subfield)
            end
            super(policy,&p)
        end

        def type_name
            type.name
        end

        def full_name
            super + "." + @subfield.join(".")
        end

        def name
            super + "." + @subfield.join(".")
        end

        def find_orocos_type_name_by_type(type)
            type = Orocos.master_project.find_opaque_for_intermediate(type) || type
            type = Orocos.master_project.find_interface_type(type)
            if Orocos.registered_type?(type.name)
                type.name
            else Typelib::Registry.rtt_typename(type)
            end
        end

        def orocos_type_name
            type.name
        end

        def new_sample
            type.new
        end

        def last_sample
            subfield(__getobj__.last_sample,@subfield)
        end

        def sub_port(subfield)
            raise RuntimeError , "Port #{name} is not an output port" if !output?
            SubPortProxy.new(__getobj__,@subfield+subfield)
        end

        def type
            @sub_type ||= if !@subfield.empty?
                          type ||= super
                          @subfield.each do |f|
                              type = if type.respond_to? :deference
                                         type.deference
                                     else
                                         type[f]
                                     end
                          end
                          type
                      else
                          super
                      end
        end

        private
        def subfield(sample,field)
            return unless sample
            field.each do |f|
                f = if f.is_a? Symbol
                        f.to_s
                    else
                        f
                    end
                sample = if !f.is_a?(Fixnum) || sample.size > f
                             sample.raw_get(f)
                         else
                             #if the field name is wrong typelib will raise an ArgumentError
                             Vizkit.warn "Cannot extract subfield for port #{full_name}: Subfield #{f} does not exist (out of index)!"
                             nil
                         end
                return nil unless sample
            end
            #check if the type is right
            if(sample.class != type)
                raise "Type miss match. Expected type #{type} but got #{sample.class} for subfield #{field.join(".")} of port #{full_name}"
            end
            sample.to_ruby
        end
    end

    class TaskContextProxy < ObjectBase
        attr_reader :name_service
        include Orocos::Namespace
        define_events :port_reachable,
                      :port_unreachable,
                      :property_reachable,
                      :property_unreachable,
                      :attribute_reachable,
                      :attribute_unreachable,
                      :state_change

        # forward methods to designated object
        extend Forwardable
        methods = Orocos::TaskContext.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods << :type
        methods -= TaskContextProxy.instance_methods + [:method_missing,:reachable?,:port]
        def_delegators :@delegator_obj,*methods

        def initialize(name,options=Hash.new)
            @options,@task_options = Kernel.filter_options options,{:name_service => Orocos::Async.name_service,
                                                       :event_loop => Orocos::Async.event_loop,
                                                       :reconnect => true,
                                                       :retry_period => Orocos::Async::TaskContextBase.default_period,
                                                       :use => nil,
                                                       :raise => false,
                                                       :wait => nil }

            @name_service = @options[:name_service]
            self.namespace,name = split_name(name)
            self.namespace ||= @name_service.namespace
            super(name,@options[:event_loop])

            @task_options[:event_loop] = @event_loop
            @mutex = Mutex.new
            @ports = Hash.new
            @attributes = Hash.new
            @properties = Hash.new
            @resolve_timer = @event_loop.async_every(@name_service.method(:get),
                                                     {:period => @options[:retry_period],:start => false},
                                                     self.name,@task_options) do |task_context,error|
                if error
                    case error
                    when Orocos::NotFound, Orocos::ComError
                        raise error if @options[:raise]
                        :ignore_error
                    else
                        raise error
                    end
                else
                    @resolve_timer.stop
                    @event_loop.async_with_options(method(:reachable!),{:sync_key => self,:known_errors => Orocos::ComError},task_context) do |val,error|
                        if error
                            @resolve_timer.start
                            :ignore_error
                        end
                    end
                end
            end
            @resolve_timer.doc = "#{name} reconnect"
            if @options.has_key?(:use)
                reachable!(@options[:use])
            else
                reconnect(@options[:wait])
            end
        end

        def name
            map_to_namespace(@name)
        end

        def basename
            @name
        end

        def to_async(options=Hash.new)
            Orocos::Async.get(name,options)
        end

        def to_proxy(options=Hash.new)
            self
        end

        # asychronsosly tries to connect to the remote task
        def reconnect(wait_for_task = false)
            @resolve_timer.start options[:retry_period]
            wait if wait_for_task == true
        end

        def property(name,options = Hash.new)
            options,other_options = Kernel.filter_options options,:wait => @options[:wait]
            wait if options[:wait]

            p = @mutex.synchronize do
                @properties[name] ||= PropertyProxy.new(self,name,other_options)
            end

            if other_options.has_key?(:type) && p.type? && other_options[:type] == p.type
                other_options.delete(:type)
            end
            if !other_options.empty? && p.options != other_options
                Orocos.warn "Property #{p.full_name}: is already initialized with options: #{p.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            if options[:wait]
                connect_property(p)
                p.wait
            else
                @event_loop.defer :known_errors => [Orocos::NotFound,Orocos::CORBA::ComError,Orocos::ComError] do
                    connect_property(p)
                end
            end
            p
        end

        def attribute(name,options = Hash.new)
            options,other_options = Kernel.filter_options options,:wait => @options[:wait]
            wait if options[:wait]

            a = @mutex.synchronize do
                @attributes[name] ||= AttributeProxy.new(self,name,other_options)
            end

            if other_options.has_key?(:type) && a.type? && other_options[:type] == a.type
                other_options.delete(:type)
            end
            if !other_options.empty? && a.options != other_options
                Orocos.warn "Attribute #{a.full_name}: is already initialized with options: #{a.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            if options[:wait]
                connect_attribute(a)
                a.wait
            else
                @event_loop.defer :known_errors => [Orocos::NotFound,Orocos::CORBA::ComError,Orocos::ComError] do
                    connect_attribute(a)
                end
            end
            a
        end

        def port(name,options = Hash.new)
            options,other_options = Kernel.filter_options options,:wait => @options[:wait]
            wait if options[:wait]

            fields = name.split(".")
            name = if fields.empty?
                       name
                   else
                       fields.shift
                   end
            type = if !fields.empty?
                       other_options.delete(:type)
                   else
                       nil
                   end

            p = @mutex.synchronize do
                @ports[name] ||= PortProxy.new(self,name,other_options)
            end

            if other_options.has_key?(:type) && p.type? && other_options[:type] == p.type
                other_options.delete(:type)
            end
            if !other_options.empty? && p.options != other_options
                Orocos.warn "Port #{p.full_name}: is already initialized with options: #{p.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            if options[:wait]
                connect_port(p)
                p.wait
            else
                @event_loop.defer :known_errors => [Orocos::ComError,Orocos::NotFound] do
                    connect_port(p)
                end
            end

            if fields.empty?
                p
            else
                p.sub_port(fields)
            end
        end

        def ports(options = Hash.new,&block)
           p = proc do |names|
               names.map{|name| port(name,options)}
           end
           if block
               port_names(&p)
           else
               p.call(port_names)
           end
        end

        def properties(&block)
           p = proc do |names|
               names.map{|name| property(name)}
           end
           if block
               property_names(&p)
           else
               p.call(property_names)
           end
        end

        def attributes(&block)
           p = proc do |names|
               names.map{|name| attribute(name)}
           end
           if block
               attribute_names(&p)
           else
               p.call(attribute_names)
           end
        end

        # call-seq:
        #  task.each_property { |a| ... } => task
        # 
        # Enumerates the properties that are available on
        # this task, as instances of Orocos::Attribute
        def each_property(&block)
            if !block_given?
                return enum_for(:each_property)
            end
            names = property_names
            names.each do |name|
                yield(property(name))
            end
        end

        # call-seq:
        #  task.each_attribute { |a| ... } => task
        # 
        # Enumerates the attributes that are available on
        # this task, as instances of Orocos::Attribute
        def each_attribute(&block)
            if !block_given?
                return enum_for(:each_attribute)
            end

            names = attribute_names
            names.each do |name|
                yield(attribute(name))
            end
        end

        # call-seq:
        #  task.each_port { |p| ... } => task
        # 
        # Enumerates the ports that are available on this task, as instances of
        # either Orocos::InputPort or Orocos::OutputPort
        def each_port(&block)
            if !block_given?
                return enum_for(:each_port)
            end

            port_names.each do |name|
                yield(port(name))
            end
            self
        end

        # must be thread safe 
        # do not emit anything because reachable will be emitted by the delegator_obj
        def reachable!(task_context,options = Hash.new)
            raise ArgumentError, "task_context must not be instance of TaskContextProxy" if task_context.is_a?(TaskContextProxy)
            raise ArgumentError, "task_context must be an async instance but is #{task_context.class}" if !task_context.respond_to?(:event_names)
            ports,attributes,properties = @mutex.synchronize do
                @last_task_class ||= task_context.class
                if @last_task_class != task_context.class
                    Vizkit.warn "Class missmatch: TaskContextProxy #{name} was recently connected to #{@last_task_class} and is now connected to #{task_context.class}."
                    @last_task_class = task_context.class
                end

                remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
                if @delegator_obj_old
                    remove_proxy_event(@delegator_obj_old,@delegator_obj_old.event_names)
                    @delegator_obj_old = nil
                end
                disable_emitting do
                    super(task_context,options)
                end
                proxy_event(@delegator_obj,@delegator_obj.event_names)
                [@ports.values,@attributes.values,@properties.values]
            end
            ports.each do |port|
                begin
                    connect_port(port)
                rescue Orocos::NotFound
                    Orocos.warn "task #{name} has currently no port called #{port.name} -> on_data will not be called!"
                rescue Orocos::CORBA::ComError => e
                    Orocos.warn "task #{name} with error on port: #{port.name} -- #{e}"
                end
            end
            attributes.each do |attribute|
                begin
                    connect_attribute(attribute)
                rescue Orocos::NotFound
                    Orocos.warn "task #{name} has currently no attribute called #{attribute.name} -> on_change will not be called!"
                rescue Orocos::CORBA::ComError => e
                    Orocos.warn "task #{name} with error on port: #{attribute.name} -- #{e}"
                end
            end
            properties.each do |property|
                begin
                    connect_property(property)
                rescue Orocos::NotFound
                    Orocos.warn "task #{name} has currently no property called #{property.name} -> on_change will not be called!"
                rescue Orocos::CORBA::ComError => e
                    Orocos.warn "task #{name} with error on port: #{property.name} -- #{e}"
                end
            end
        end

        def reachable?
            @mutex.synchronize do
                super && @delegator_obj.reachable?
            end
        rescue Orocos::NotFound => e
            unreachable! :error => e,:reconnect => @options[:reconnect]
            false
        end

        def unreachable!(options = {:reconnect => false})
            Kernel.validate_options options,:reconnect,:error
            @mutex.synchronize do
                # do not stop proxing events here (see reachable!)
                # otherwise unrechable event might get lost
                @delegator_obj_old = if valid_delegator?
                                         @delegator_obj
                                     else
                                         @delegator_obj_old
                                     end

                disable_emitting do
                    super(options)
                end
            end
            disconnect_ports
            disconnect_attributes
            disconnect_properties
            re = if options.has_key?(:reconnect)
                    options[:reconnect]
                 else
                    @options[:reconnect]
                 end
            reconnect if re
        end

        private
        # blocking call shoud be called from a different thread
        # all private methods must be thread safe
        def connect_port(port)
            p = @mutex.synchronize do
                return unless valid_delegator?
                @delegator_obj.disable_emitting do
                    #called in the context of @delegator_obj
                    port(port.name,true,port.options)
                end
            end
            @event_loop.call do
                port.reachable!(p)
            end
        end

        def disconnect_ports
            ports = @mutex.synchronize do
                @ports.values
            end
            ports.each(&:unreachable!)
        end

        # blocking call shoud be called from a different thread
        def connect_attribute(attribute)
            a = @mutex.synchronize do
                return unless valid_delegator?
                @delegator_obj.disable_emitting do
                    #called in the context of @delegator_obj
                    attribute(attribute.name,attribute.options)
                end
            end
            @event_loop.call do
                attribute.reachable!(a)
            end
        end

        def disconnect_attributes
            attributes = @mutex.synchronize do 
                @attributes.values
            end
            attributes.each(&:unreachable!)
        end

        # blocking call shoud be called from a different thread
        def connect_property(property)
            p = @mutex.synchronize do
                return unless valid_delegator?
                @delegator_obj.disable_emitting do
                    #called in the context of @delegator_obj
                    property(property.name,property.options)
                end
            end
            @event_loop.call do
                property.reachable!(p)
            end
        end

        def disconnect_properties
            properties = @mutex.synchronize do
                @properties.values
            end
            properties.each(&:unreachable!)
        end

        def respond_to_missing?(method_name, include_private = false)
            (reachable? && @delegator_obj.respond_to?(method_name)) || super
        end

        def method_missing(m,*args)
            if respond_to_missing?(m)
                event_loop.sync(@delegator_obj,args) do |args|
                    @delegator_obj.method(m).call(*args)
                end
            else
                super
            end
        end
    end
end
