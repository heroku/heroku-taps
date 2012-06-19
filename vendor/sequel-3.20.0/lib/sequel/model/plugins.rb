module Sequel
  # Empty namespace that plugins should use to store themselves,
  # so they can be loaded via Model.plugin.
  #
  # Plugins should be modules with one of the following conditions:
  # * A singleton method named apply, which takes a model, 
  #   additional arguments, and an optional block.  This is called
  #   the first time the plugin is loaded for this model (unless it was
  #   already loaded by an ancestor class), before including/extending
  #   any modules, with the arguments
  #   and block provided to the call to Model.plugin.
  # * A module inside the plugin module named InstanceMethods,
  #   which will be included in the model class.
  # * A module inside the plugin module named ClassMethods,
  #   which will extend the model class.
  # * A module inside the plugin module named DatasetMethods,
  #   which will extend the model's dataset.
  # * A singleton method named configure, which takes a model, 
  #   additional arguments, and an optional block.  This is called
  #   every time the Model.plugin method is called, after including/extending
  #   any modules.
  module Plugins
  end
  
  class Model
    # Loads a plugin for use with the model class, passing optional arguments
    # to the plugin.  If the plugin is a module, load it directly.  Otherwise,
    # require the plugin from either sequel/plugins/#{plugin} or
    # sequel_#{plugin}, and then attempt to load the module using a
    # the camelized plugin name under Sequel::Plugins.
    def self.plugin(plugin, *args, &blk)
      m = plugin.is_a?(Module) ? plugin : plugin_module(plugin)
      unless @plugins.include?(m)
        @plugins << m
        m.apply(self, *args, &blk) if m.respond_to?(:apply)
        include(m::InstanceMethods) if m.const_defined?("InstanceMethods")
        extend(m::ClassMethods)if m.const_defined?("ClassMethods")
        if m.const_defined?("DatasetMethods")
          dataset.extend(m::DatasetMethods) if @dataset
          dataset_method_modules << m::DatasetMethods
          meths = m::DatasetMethods.public_instance_methods.reject{|x| NORMAL_METHOD_NAME_REGEXP !~ x.to_s}
          def_dataset_method(*meths) unless meths.empty?
        end
      end
      m.configure(self, *args, &blk) if m.respond_to?(:configure)
    end
    
    module ClassMethods
      # Array of plugin modules loaded by this class
      #
      #   Sequel::Model.plugins
      #   # => [Sequel::Model, Sequel::Model::Associations]
      attr_reader :plugins
      
      private
  
      # Returns the module for the specified plugin. If the module is not 
      # defined, the corresponding plugin required.
      def plugin_module(plugin)
        module_name = plugin.to_s.gsub(/(^|_)(.)/){|x| x[-1..-1].upcase}
        if !Sequel::Plugins.const_defined?(module_name) ||
           (Sequel.const_defined?(module_name) &&
            Sequel::Plugins.const_get(module_name) == Sequel.const_get(module_name))
          begin
            Sequel.tsk_require "sequel/plugins/#{plugin}"
          rescue LoadError => e
            begin
              Sequel.tsk_require "sequel_#{plugin}"
            rescue LoadError => e2
              e.message << "; #{e2.message}"
              raise e
            end
          end
        end
        Sequel::Plugins.const_get(module_name)
      end
    end
  end
end
