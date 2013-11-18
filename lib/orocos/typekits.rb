module Types
end

module Orocos
    class << self
        # The set of typekits whose shared libraries have been loaded in this
        # process
        attr_reader :loaded_typekit_plugins

        # The set of typekits whose registries have been merged in the master registry
        attr_reader :loaded_typekit_registries

        # If true, the types that get loaded are exported in the Ruby namespace.
        # For instance, a /base/Pose type included in Orocos.registry will be
        # available as Base::Pose
        #
        # The export can be done in a sub-namespace by setting
        # Orocos.type_export_namespace
        attr_predicate :export_types?, true

        # The namespace in which the types should be exported if
        # Orocos.export_types? is true. It defaults to Types
        attr_accessor :type_export_namespace

        # List of already loaded plugins, as a set of full paths to the shared
        # library
        attr_reader :loaded_plugins
    end
    @loaded_typekit_plugins = []
    @loaded_typekit_registries = []
    @loaded_plugins = Set.new
    @failed_plugins = Set.new
    @export_types = true
    @type_export_namespace = Types

    # Given a pkg-config file and a base name for a shared library, finds the
    # full path to the library
    def self.find_plugin_library(pkg, libname)
        pkg.library_dirs.find do |dir|
            full_path = File.join(dir, "lib#{libname}.so")
            break(full_path) if File.file?(full_path)
        end
    end

    # Generic loading of a RTT plugin
    def self.load_plugin_library(libpath) # :nodoc:
        return if @loaded_plugins.include?(libpath)
        if @failed_plugins.include?(libpath)
            @failed_plugins << libpath
            raise "the RTT plugin system already refused to load #{libpath}, I'm not trying again"
        end
        begin
            Orocos.info "loading plugin library #{libpath}"
            if !Orocos.load_rtt_plugin(libpath)
                raise "the RTT plugin system refused to load #{libpath}"
            end
            @loaded_plugins << libpath
        rescue Exception
            @failed_plugins << libpath
            raise
        end
        true
    end

    # The set of transports that should be automatically loaded. The associated
    # boolean is true if an exception should be raised if the typekit fails to
    # load, and false otherwise
    AUTOLOADED_TRANSPORTS = {
        'typelib' => true,
        'corba' => true,
        'mqueue' => false,
        'ros' => false
    }

    @lock = Mutex.new

    # Load the typekit whose name is given
    #
    # Typekits are shared libraries that include marshalling/demarshalling
    # code. It gets automatically loaded in orocos.rb whenever you start
    # processes.
    def self.load_typekit(name)
        @lock.synchronize do
            typekit = default_loader.typekit_model_from_name(name)
            typekit_pkg = find_typekit_pkg(name)
            load_typekit_plugins(name, typekit_pkg)
        end
    end

    def self.find_typekit_pkg(name)
        begin
            Utilrb::PkgConfig.new("#{name}-typekit-#{Orocos.orocos_target}")
        rescue Utilrb::PkgConfig::NotFound
            raise NotFound, "the '#{name}' typekit is not available to pkgconfig"
        end
    end

    def self.load_typekit_plugins(name, typekit_pkg = nil)
        if @loaded_typekit_plugins.include?(name)
            return
        end

        find_typekit_plugin_paths(name, typekit_pkg).each do |path, required|
            begin
                load_plugin_library(path)
            rescue Exception => e
                if required
                    raise
                else
                    Orocos.warn "plugin #{p}, which is registered as an optional transport for the #{name} typekit, cannot be loaded"
                    Orocos.log_pp(:warn, e)
                end
            end
        end
        @loaded_typekit_plugins << name
    end

    def self.export_registry_to_ruby
        Orocos.registry.export_to_ruby(Orocos.type_export_namespace) do |type_name, base_type, mod, basename, exported_type|
            if type_name =~ /orogen_typekits/ # just ignore those
            elsif base_type <= Typelib::NumericType # using numeric is transparent in Typelib/Ruby
            elsif base_type.contains_opaques? # register the intermediate instead
                master_typekit.intermediate_type_for(base_type)
            elsif master_typekit.m_type?(base_type) # just ignore, they are registered as the opaque
            else exported_type
            end
        end
    end

    # Loads all typekits that are available on this system
    def self.load_all_typekits
        default_pkgconfig_loader.available_typekits.each_key do |typekit_name|
            load_typekit(typekit_name)
        end
    end

    def self.typekit_library_name(typekit_name, target)
        "#{typekit_name}-typekit-#{target}"
    end

    def self.transport_library_name(typekit_name, transport_name, target)
        "#{typekit_name}-transport-#{transport_name}-#{target}"
    end

    # For backward compatibility only. Use #find_typekit_plugin_paths instead
    def self.plugin_libs_for_name(name)
        find_typekit_plugin_paths(name).map(&:first)
    end

    # Returns the full path of all the plugin libraries that should be loaded
    # for the given typekit
    #
    # If given, +typekit_pkg+ is the PkgConfig file for the requested typekit
    #
    # @return [Array<(String,Boolean)>] set of found libraries. The string is
    #   the path to the library and the boolean flag indicates whether loading
    #   this library is optional (from orocos.rb's point of view), or required
    #   to use the typekit-defined types on transports
    def self.find_typekit_plugin_paths(name, typekit_pkg = nil)
        plugins = Hash.new
        libs = Array.new

        plugin_name = typekit_library_name(name, Orocos.orocos_target)
        plugins[plugin_name] = [typekit_pkg || find_typekit_pkg(name), true]
        if Orocos::Generation::VERSION >= "0.8"
            AUTOLOADED_TRANSPORTS.each do |transport_name, required|
                plugin_name = transport_library_name(name, transport_name, Orocos.orocos_target)
                begin
                    plugins[plugin_name] = [Utilrb::PkgConfig.new(plugin_name), required]
                rescue Utilrb::PkgConfig::NotFound => e
                    if required
                        raise NotFound, "the '#{name}' typekit has no #{transport_name} transport: could not find pkg-config package #{e.name} in #{ENV['PKG_CONFIG_PATH']}"
                    end
                end
            end
        end

        plugins.each_pair do |file, (pkg, required)| 
            lib = find_plugin_library(pkg, file)
            if !lib
                if required
                    raise NotFound, "cannot find shared library #{file} for #{name} (searched in #{pkg.library_dirs.join(", ")})"
                else
                    Orocos.warn "plugin #{file} is registered through pkg-config, but the library cannot be found in #{pkg.library_dirs.join(", ")}"
                end
            end
            libs << [lib, required]
        end
        libs
    end

    TypekitTypeNotFound = OroGen::Loaders::PkgConfig::TypekitTypeNotFound
    TypekitTypeNotExported = OroGen::Loaders::PkgConfig::TypekitTypeNotExported

    # Looks for and loads the typekit that handles the specified type
    #
    # If +exported+ is true (the default), the type needs to be both defined and
    # exported by the typekit.
    #
    # Raises ArgumentError if this type is registered nowhere, or if +exported+
    # is true and the type is not exported.
    def self.load_typekit_for(typename, exported = true)
        default_pkgconfig_loader.typekit_for(typename, exported)
    end

    # Returns the type that is used to manipulate +t+ in Typelib
    #
    # For simple types, it is +t+ itself. For opaque types, it will be the
    # corresponding marshalling type. The returned value is a subclass of
    # Typelib::Type
    #
    # Raises Typelib::NotFound if this type is not registered anywhere.
    def self.typelib_type_for(t)
        if t.respond_to?(:name)
            return t if !t.contains_opaques?
            t = t.name
        end

        begin
            if typelib_type = do_typelib_type_for(t)
                return registry.get(typelib_type)
            end
        rescue ArgumentError
        end

        if registry.include?(t)
            type = registry.get(t)
            if type.contains_opaques?
                master_typekit.intermediate_type_for(type)
            elsif type.null?
                # 't' is an opaque type and there are no typelib marshallers
                # to convert it to something we can manipulate, raise
                raise Typelib::NotFound, "#{t} is an opaque type and there are no typelib marshallers registered in RTT to convert it to a typelib-compatible type"
            else type
            end
        else
            raise Typelib::NotFound, "#{t} cannot be found in the currently loaded registries"
        end
    end

    def self.create_or_get_null_type(type_name)
        if registry.include?(type_name)
            type = registry.get type_name
            if !type.null?
                return create_or_get_null_type("/orocos#{type_name}")
            end
            type
        else
            registry.create_null(type_name)
        end
    end

    # Finds the C++ type that maps to the given typelib type name
    #
    # @param [Typelib::Type,String] typelib_type
    def self.orocos_type_for(typelib_type)
        master_project.find_opaque_for_intermediate(typelib_type) || typelib_type
    end

    # Finds the typelib type that maps to the given orocos type name
    #
    # @param [String] orocos_type_name
    # @option options [Boolean] :fallback_to_null_type (false) if true, a new
    #   null type with the given orocos type name will be added to the registry and
    #   returned if the type cannot be found
    #
    # @raise [Orocos::TypekitTypeNotFound] if the type cannot be found and no
    #   typekit registers it
    # @return [Model<Typelib::Type>] a subclass of Typelib::Type that
    #   represents the requested type
    def self.find_type_by_orocos_type_name(orocos_type_name, options = Hash.new)
        options = Kernel.validate_options options,
            :fallback_to_null_type => false

        if !registered_type?(orocos_type_name)
            load_typekit_for(orocos_type_name)
        end
        typelib_type_for(orocos_type_name)
    rescue Orocos::TypekitTypeNotFound, Typelib::NotFound
        # Create an opaque type as a placeholder for the unknown
        # type name
        if options[:fallback_to_null_type]
            type_name = '/' + orocos_type_name.gsub(/[^\w]/, '_')
            create_or_get_null_type(type_name)
        else raise
        end
    end

    def find_orocos_type_name_by_type(type)
        if type.respond_to?(:name)
            type = type.name
        end
        type = master_typekit.resolve_type(type)
        type = master_typekit.find_opaque_for_intermediate(type) || type
        type = master_typekit.find_interface_type(type)
        if registered_type?(type.name)
            type.name
        else Typelib::Registry.rtt_typename(type)
        end
    end
end

