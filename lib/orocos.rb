require 'rorocos_ext'
require 'orogen'

require 'orocos/base'
require 'orocos/typekits'

begin
    require 'pocolog'
    Orocos::HAS_POCOLOG = true
rescue LoadError
    Orocos::HAS_POCOLOG = false
end

require 'orocos/logging'
require 'orocos/version'
require 'orocos/task_context'
require 'orocos/ports'
require 'orocos/operations'
require 'orocos/process'
require 'orocos/corba'
require 'orocos/mqueue'

require 'utilrb/hash/recursive_merge'
require 'orocos/configurations'

require 'orocos/extensions'
