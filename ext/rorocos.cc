#include "rorocos.hh"
#include <typeinfo>

#include <memory>
#include <boost/tuple/tuple.hpp>

#include <rtt/types/Types.hpp>
#include <rtt/types/TypekitPlugin.hpp>
#include <rtt/types/TypekitRepository.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/base/PortInterface.hpp>
#include <rtt/transports/corba/TransportPlugin.hpp>
#include <rtt/plugin/PluginLoader.hpp>

#include <rtt/base/OutputPortInterface.hpp>
#include <rtt/base/InputPortInterface.hpp>

#include <typelib_ruby.hh>
#include <rtt/transports/corba/CorbaLib.hpp>
#ifdef HAS_MQUEUE
#include <rtt/transports/mqueue/MQLib.hpp>
#include <fcntl.h>
#include <sys/stat.h>
#include <mqueue.h>
#include <boost/lexical_cast.hpp>
#endif

using namespace std;
using namespace boost;
using namespace RTT::corba;

static VALUE mOrocos;
static VALUE cTaskContext;
static VALUE cInputPort;
static VALUE cOutputPort;
static VALUE cPortAccess;
static VALUE cInputWriter;
static VALUE cOutputReader;
static VALUE cPort;
VALUE eNotFound;
static VALUE eConnectionFailed;
static VALUE eStateTransitionFailed;

extern void Orocos_init_CORBA();
extern void Orocos_init_data_handling(VALUE cTaskContext);
extern void Orocos_init_methods();
static RTT::corba::CConnPolicy policyFromHash(VALUE options);

RTT::types::TypeInfo* get_type_info(std::string const& name, bool do_check)
{
    RTT::types::TypeInfoRepository::shared_ptr type_registry = RTT::types::TypeInfoRepository::Instance();
    RTT::types::TypeInfo* ti = type_registry->type(name);
    if (do_check && ! ti)
        rb_raise(rb_eArgError, "type '%s' is not registered in the RTT type system", name.c_str());
    return ti;
}

RTT::corba::CorbaTypeTransporter* get_corba_transport(std::string const& name, bool do_check)
{
    RTT::types::TypeInfo* ti = get_type_info(name, do_check);
    if (!ti) return 0;
    return get_corba_transport(ti, do_check);
}

RTT::corba::CorbaTypeTransporter* get_corba_transport(RTT::types::TypeInfo* ti, bool do_check)
{
    if (ti->hasProtocol(ORO_CORBA_PROTOCOL_ID))
        return dynamic_cast<RTT::corba::CorbaTypeTransporter*>(ti->getProtocol(ORO_CORBA_PROTOCOL_ID));
    else if (do_check)
        rb_raise(rb_eArgError, "type '%s' does not have a CORBA transport", ti->getTypeName().c_str());
    else
        return 0;
}

orogen_transports::TypelibMarshallerBase* get_typelib_transport(std::string const& name, bool do_check)
{
    RTT::types::TypeInfo* ti = get_type_info(name, do_check);
    if (!ti) return 0;
    return get_typelib_transport(ti, do_check);
}

orogen_transports::TypelibMarshallerBase* get_typelib_transport(RTT::types::TypeInfo* ti, bool do_check)
{
    if (ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
        return dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
    else if (do_check)
        rb_raise(rb_eArgError, "type '%s' does not have a typelib transport", ti->getTypeName().c_str());
    else
        return 0;
}

tuple<RTaskContext*, VALUE, VALUE> getPortReference(VALUE port)
{
    VALUE task = rb_iv_get(port, "@task");
    VALUE task_name = rb_iv_get(task, "@name");
    VALUE port_name = rb_iv_get(port, "@name");

    RTaskContext& task_context = get_wrapped<RTaskContext>(task);
    return make_tuple(&task_context, task_name, port_name);
}

static VALUE orocos_do_task_names(VALUE mod)
{
    VALUE result = rb_ary_new();

    list<string> names = CorbaAccess::instance()->knownTasks();
    for (list<string>::const_iterator it = names.begin(); it != names.end(); ++it)
        rb_ary_push(result, rb_str_new2(it->c_str()));

    return result;
}

// call-seq:
//  TaskContext.get(name) => task
//
// Returns the TaskContext instance representing the remote task context
// with the given name. Raises Orocos::NotFound if the task name does
// not exist.
///
static VALUE task_context_get(VALUE klass, VALUE name)
{
    try {
        std::auto_ptr<RTaskContext> new_context( new RTaskContext );
        new_context->task       = CorbaAccess::instance()->findByName(StringValuePtr(name));
        new_context->main_service = new_context->task->getProvider("this");
        new_context->ports      = new_context->task->ports();

        VALUE obj = simple_wrap(cTaskContext, new_context.release());
        return obj;
    }
    CORBA_EXCEPTION_HANDLERS;
}

static VALUE task_context_get_from_ior(VALUE klass, VALUE ior)
{
    try {
        std::auto_ptr<RTaskContext> new_context( new RTaskContext );
        new_context->task       = CorbaAccess::instance()->findByIOR(StringValuePtr(ior));

        new_context->main_service = new_context->task->getProvider("this");
        new_context->ports      = new_context->task->ports();

        VALUE obj = simple_wrap(cTaskContext, new_context.release());
        return obj;
    }
    CORBA_EXCEPTION_HANDLERS;
}

static VALUE task_context_equal_p(VALUE self, VALUE other)
{
    if (!rb_obj_is_kind_of(other, cTaskContext))
        return Qfalse;

    RTaskContext& self_  = get_wrapped<RTaskContext>(self);
    RTaskContext& other_ = get_wrapped<RTaskContext>(other);
    return self_.task->_is_equivalent(other_.task) ? Qtrue : Qfalse;
}

// call-seq:
//   task.has_port?(name) => true or false
//
// Returns true if the given name is the name of a port on this task context,
// and false otherwise
///
static VALUE task_context_has_port_p(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    try {
        context.ports->getPortType(StringValuePtr(name));
    }
    catch(RTT::corba::CNoSuchPortException) { return Qfalse; }
    CORBA_EXCEPTION_HANDLERS
    return Qtrue;
}

static VALUE task_context_has_operation_p(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    try {
        context.main_service->getResultType(StringValuePtr(name));
    }
    catch(RTT::corba::CNoSuchNameException) { return Qfalse; }
    CORBA_EXCEPTION_HANDLERS
    return Qtrue;
}

static VALUE task_context_attribute_type_name(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    std::string const expected_name = StringValuePtr(name);
    try {
        CORBA::String_var attribute_type_name =
            context.main_service->getAttributeTypeName(StringValuePtr(name));
        std::string type_name = std::string(attribute_type_name);
        if (type_name != "na")
            return rb_str_new(type_name.c_str(), type_name.length());

        rb_raise(rb_eArgError, "no such attribute %s", StringValuePtr(name));
    }
    CORBA_EXCEPTION_HANDLERS
    return Qfalse;
}

static VALUE task_context_property_type_name(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    std::string const expected_name = StringValuePtr(name);
    try {
        CORBA::String_var attribute_type_name =
            context.main_service->getPropertyTypeName(StringValuePtr(name));
        std::string type_name = std::string(attribute_type_name);
        if (type_name != "na")
            return rb_str_new(type_name.c_str(), type_name.length());

        rb_raise(rb_eArgError, "no such property %s", StringValuePtr(name));
    }
    CORBA_EXCEPTION_HANDLERS
    return Qfalse;
}

static VALUE task_context_property_names(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);

    VALUE result = rb_ary_new();
    try {
        RTT::corba::CConfigurationInterface::CPropertyNames_var names =
            context.main_service->getPropertyList();
        for (int i = 0; i != names->length(); ++i)
        {
            CORBA::String_var name = names[i].name;
            rb_ary_push(result, rb_str_new2(name));
        }
    }
    CORBA_EXCEPTION_HANDLERS
    return result;
}

static VALUE task_context_attribute_names(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);

    VALUE result = rb_ary_new();
    try {
        RTT::corba::CConfigurationInterface::CAttributeNames_var names =
            context.main_service->getAttributeList();
        for (int i = 0; i != names->length(); ++i)
        {
            CORBA::String_var name = names[i];
            rb_ary_push(result, rb_str_new2(name));
        }
    }
    CORBA_EXCEPTION_HANDLERS
    return result;
}

// call-seq:
//   task.do_port(name) => port
//
// Returns the Orocos::DataPort or Orocos::BufferPort object representing the
// remote port +name+. Raises NotFound if the port does not exist. This is an
// internal method. Use TaskContext#port to get a port object.
///
static VALUE task_context_do_port(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    RTT::corba::CPortType port_type;
    CORBA::String_var    type_name;
    try {
        port_type = context.ports->getPortType(StringValuePtr(name));
        type_name = context.ports->getDataType(StringValuePtr(name));
    }
    catch(RTT::corba::CNoSuchPortException)
    { 
        VALUE task_name = rb_iv_get(self, "@name");
        rb_raise(eNotFound, "task %s does not have a '%s' port",
                StringValuePtr(task_name),
                StringValuePtr(name));
    }
    CORBA_EXCEPTION_HANDLERS

    VALUE obj = Qnil;
    if (port_type == RTT::corba::CInput)
    {
        auto_ptr<RInputPort> rport( new RInputPort );
        obj = simple_wrap(cInputPort, rport.release());
    }
    else if (port_type == RTT::corba::COutput)
    {
        auto_ptr<ROutputPort> rport( new ROutputPort );
        obj = simple_wrap(cOutputPort, rport.release());
    }

    rb_iv_set(obj, "@name", rb_str_dup(name));
    rb_iv_set(obj, "@task", self);
    rb_iv_set(obj, "@orocos_type_name", rb_str_new2(type_name));

    rb_funcall(obj, rb_intern("initialize"), 0);
    return obj;
}

static VALUE orocos_registered_type_p(VALUE mod, VALUE type_name)
{
    RTT::types::TypeInfo* ti = get_type_info(static_cast<char const*>(StringValuePtr(type_name)), false);
    return ti ? Qtrue : Qfalse;
}

static VALUE orocos_typelib_type_for(VALUE mod, VALUE type_name)
{
    RTT::types::TypeInfo* ti = get_type_info(static_cast<char const*>(StringValuePtr(type_name)), false);
    if (!ti)
        rb_raise(rb_eArgError, "the type %s is not registered in the RTT type system, has the typekit been generated by orogen ?",
                StringValuePtr(type_name));

    if (ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
    {
        orogen_transports::TypelibMarshallerBase* transport =
            dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
        return rb_str_new2(transport->getMarshallingType());
    }
    else
        return type_name;
}

static VALUE task_context_each_port(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    try {
        RTT::corba::CDataFlowInterface::CPortNames_var ports = context.ports->getPorts();

        for (unsigned int i = 0; i < ports->length(); ++i)
            rb_yield(task_context_do_port(self, rb_str_new2(ports[i])));
    }
    CORBA_EXCEPTION_HANDLERS

    return self;
}

static void delete_port(RTT::base::PortInterface* port)
{
    // At process shutdown, CorbaAccess::instance() might be deinitialized
    // BEFORE the port gets garbage collected. In this case, we have nothing to
    // do
    if (CorbaAccess::instance())
    {
        port->disconnect();
        CorbaAccess::instance()->removePort(port);
        delete port;
    }
}

static VALUE do_input_port_writer(VALUE port, VALUE type_name, VALUE policy)
{
    CorbaAccess* corba = CorbaAccess::instance();

    // Get the port and create an anti-clone of it
    RTaskContext* task; VALUE port_name;
    tie(task, tuples::ignore, port_name) = getPortReference(port);
    RTT::types::TypeInfo* ti = get_type_info(StringValuePtr(type_name));

    std::string local_name = corba->getLocalPortName(port);
    RTT::base::PortInterface* local_port = ti->outputPort(local_name);

    // Register this port on our data flow interface, and call CORBA to connect
    // both ports
    corba->addPort(local_port);
    try {
        RTT::corba::CConnPolicy corba_policy = policyFromHash(policy);
	bool result = corba->getDataFlowInterface()->createConnection(local_name.c_str(),
		task->ports, StringValuePtr(port_name),
		corba_policy);
        if (!local_port->connected() || !result)
        {
            corba->removePort(local_port);
            rb_raise(eConnectionFailed, "failed to connect the writer object to its remote port");
        }
    }
    CORBA_EXCEPTION_HANDLERS

    // Finally, wrap the new port in a Ruby object
    VALUE robj = Data_Wrap_Struct(cInputWriter, 0, delete_port, local_port);
    rb_iv_set(robj, "@port", port);
    return robj;
}

static VALUE do_output_port_reader(VALUE port, VALUE klass, VALUE type_name, VALUE policy)
{
    CorbaAccess* corba = CorbaAccess::instance();

    // Get the port and create an anti-clone of it
    RTaskContext* task; VALUE port_name;
    tie(task, tuples::ignore, port_name) = getPortReference(port);
    RTT::types::TypeInfo* ti = get_type_info(StringValuePtr(type_name));

    std::string local_name = corba->getLocalPortName(port);
    RTT::base::PortInterface* local_port = ti->inputPort(local_name);

    // Register this port on our data flow interface, and call CORBA to connect
    // both ports
    corba->addPort(local_port);
    try {
        RTT::corba::CConnPolicy corba_policy = policyFromHash(policy);
        bool result = task->ports->createConnection(StringValuePtr(port_name),
                corba->getDataFlowInterface(), local_name.c_str(),
                corba_policy);
        if (!result)
        {
            corba->removePort(local_port);
            rb_raise(eConnectionFailed, "failed to connect specified ports");
        }
    }
    CORBA_EXCEPTION_HANDLERS

    // Finally, wrap the new port in a Ruby object
    VALUE robj = Data_Wrap_Struct(klass, 0, delete_port, local_port);
    rb_iv_set(robj, "@port", port);
    return robj;
}

// call-seq:
//  task.state => value
//
// Returns the state of the task, as an integer value. The possible values are
// represented by the various +STATE_+ constants:
// 
//   STATE_PRE_OPERATIONAL
//   STATE_STOPPED
//   STATE_ACTIVE
//   STATE_RUNNING
//   STATE_RUNTIME_WARNING
//   STATE_RUNTIME_ERROR
//   STATE_FATAL_ERROR
//
// See Orocos own documentation for their meaning
///
static VALUE task_context_state(VALUE task)
{
    RTaskContext& context = get_wrapped<RTaskContext>(task);
    try { return INT2FIX(context.task->getTaskState()); }
    CORBA_EXCEPTION_HANDLERS
}

static VALUE call_checked_state_change(VALUE task, char const* msg, bool (RTT::corba::_objref_CTaskContext::*m)())
{
    RTaskContext& context = get_wrapped<RTaskContext>(task);
    try
    {
        RTT::corba::_objref_CTaskContext& obj = *context.task;
        if (!((obj.*m)()))
            rb_raise(eStateTransitionFailed, msg);
        return Qnil;
    }
    CORBA_EXCEPTION_HANDLERS
}

// Do the transition between STATE_PRE_OPERATIONAL and STATE_STOPPED
static VALUE task_context_configure(VALUE task)
{
    return call_checked_state_change(task, "failed to configure", &RTT::corba::_objref_CTaskContext::configure);
}

// Do the transition between STATE_STOPPED and STATE_RUNNING
static VALUE task_context_start(VALUE task)
{
    return call_checked_state_change(task, "failed to start", &RTT::corba::_objref_CTaskContext::start);
}

// Do the transition between STATE_RUNNING and STATE_STOPPED
static VALUE task_context_stop(VALUE task)
{
    return call_checked_state_change(task, "failed to stop", &RTT::corba::_objref_CTaskContext::stop);
}

// Do the transition between STATE_STOPPED and STATE_PRE_OPERATIONAL
static VALUE task_context_cleanup(VALUE task)
{
    return call_checked_state_change(task, "failed to cleanup", &RTT::corba::_objref_CTaskContext::cleanup);
}

// Do the transition between STATE_EXCEPTION and STATE_STOPPED
static VALUE task_context_reset_exception(VALUE task)
{
    return call_checked_state_change(task, "failed to transition from the Exception state to Stopped", &RTT::corba::_objref_CTaskContext::resetException);
}

/* call-seq:
 *  port.connected? => true or false
 *
 * Tests if this port is already part of a connection or not
 */
static VALUE port_connected_p(VALUE self)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(self);

    try
    { return task->ports->isConnected(StringValuePtr(name)) ? Qtrue : Qfalse; }
    catch(RTT::corba::CNoSuchPortException&) { rb_raise(eNotFound, "no such port"); } // is refined on the Ruby side
    CORBA_EXCEPTION_HANDLERS
    return Qnil; // never reached
}

static RTT::corba::CConnPolicy policyFromHash(VALUE options)
{
    RTT::corba::CConnPolicy result;
    VALUE conn_type = SYM2ID(rb_hash_aref(options, ID2SYM(rb_intern("type"))));
    if (conn_type == rb_intern("data"))
        result.type = RTT::corba::CData;
    else if (conn_type == rb_intern("buffer"))
        result.type = RTT::corba::CBuffer;
    else
    {
        VALUE obj_as_str = rb_funcall(conn_type, rb_intern("inspect"), 0);
        rb_raise(rb_eArgError, "invalid connection type %s", StringValuePtr(obj_as_str));
    }

    result.transport = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("transport"))));
    result.data_size = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("data_size"))));
    result.init = RTEST(rb_hash_aref(options, ID2SYM(rb_intern("init"))));
    result.pull = RTEST(rb_hash_aref(options, ID2SYM(rb_intern("pull"))));
    result.size = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("size"))));

    VALUE lock_type = SYM2ID(rb_hash_aref(options, ID2SYM(rb_intern("lock"))));
    if (lock_type == rb_intern("locked"))
        result.lock_policy = RTT::corba::CLocked;
    else if (lock_type == rb_intern("lock_free"))
        result.lock_policy = RTT::corba::CLockFree;
    else
    {
        VALUE obj_as_str = rb_funcall(lock_type, rb_intern("to_s"), 0);
        rb_raise(rb_eArgError, "invalid locking type %s", StringValuePtr(obj_as_str));
    }
    return result;
}

/* Actual implementation of #connect_to. Sanity checks are done in Ruby. Just
 * create the connection. 
 */
static VALUE do_port_connect_to(VALUE routput_port, VALUE rinput_port, VALUE options)
{
    RTaskContext* out_task; VALUE out_name;
    tie(out_task, tuples::ignore, out_name) = getPortReference(routput_port);
    RTaskContext* in_task; VALUE in_name;
    tie(in_task, tuples::ignore, in_name) = getPortReference(rinput_port);

    RTT::corba::CConnPolicy policy = policyFromHash(options);

    try
    {
        if (!out_task->ports->createConnection(StringValuePtr(out_name),
                in_task->ports, StringValuePtr(in_name),
                policy))
            rb_raise(eConnectionFailed, "failed to connect ports");
        return Qnil;
    }
    catch(RTT::corba::CNoSuchPortException&) { rb_raise(eNotFound, "no such port"); } // should be refined on the Ruby side
    CORBA_EXCEPTION_HANDLERS
    return Qnil; // never reached
}

static VALUE do_port_disconnect_all(VALUE port)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(port);

    try
    {
        task->ports->disconnectPort(StringValuePtr(name));
        return Qnil;
    }
    catch(RTT::corba::CNoSuchPortException&) { rb_raise(eNotFound, "no such port"); }
    CORBA_EXCEPTION_HANDLERS
    return Qnil; // never reached
}

static VALUE do_port_disconnect_from(VALUE self, VALUE other)
{
    RTaskContext* self_task; VALUE self_name;
    tie(self_task, tuples::ignore, self_name) = getPortReference(self);
    RTaskContext* other_task; VALUE other_name;
    tie(other_task, tuples::ignore, other_name) = getPortReference(other);

    try
    {
        bool result = self_task->ports->removeConnection(StringValuePtr(self_name), other_task->ports, StringValuePtr(other_name));
        return result ? Qtrue : Qfalse;
    }
    catch(RTT::corba::CNoSuchPortException&) { rb_raise(eNotFound, "no such port"); }
    CORBA_EXCEPTION_HANDLERS
    return Qnil; // never reached
}

static VALUE do_output_reader_read(VALUE port_access, VALUE type_name, VALUE rb_typelib_value, VALUE copy_old_data)
{
    RTT::base::InputPortInterface& local_port = get_wrapped<RTT::base::InputPortInterface>(port_access);
    Typelib::Value value = typelib_get(rb_typelib_value);

    RTT::types::TypeInfo* ti = get_type_info(StringValuePtr(type_name));
    orogen_transports::TypelibMarshallerBase* typelib_transport =
        get_typelib_transport(ti, false);

    if (!typelib_transport || typelib_transport->isPlainTypelibType())
    {
        RTT::base::DataSourceBase::shared_ptr ds =
            ti->buildReference(value.getData());
        switch(local_port.read(ds))
        {
            case RTT::NoData:  return Qfalse;
            case RTT::OldData: return INT2FIX(0);
            case RTT::NewData: return INT2FIX(1);
        }
    }
    else
    {
        orogen_transports::TypelibMarshallerBase::Handle* handle =
            typelib_transport->createHandle();
        // Set the typelib sample using the value passed from ruby to avoid
        // unnecessary convertions. Don't touch the orocos sample though.
        typelib_transport->setTypelibSample(handle, value, false);
        RTT::base::DataSourceBase::shared_ptr ds =
            typelib_transport->getDataSource(handle);
        RTT::FlowStatus did_read = local_port.read(ds, RTEST(copy_old_data));

        if (did_read == RTT::NewData || (did_read == RTT::OldData && RTEST(copy_old_data)))
        {
            typelib_transport->refreshTypelibSample(handle);
            Typelib::copy(value, Typelib::Value(typelib_transport->getTypelibSample(handle), value.getType()));
        }

        typelib_transport->deleteHandle(handle);
        switch(did_read)
        {
            case RTT::NoData:  return Qfalse;
            case RTT::OldData: return INT2FIX(0);
            case RTT::NewData: return INT2FIX(1);
        }
    }
}
static VALUE output_reader_clear(VALUE port_access)
{
    RTT::base::InputPortInterface& local_port = get_wrapped<RTT::base::InputPortInterface>(port_access);
    local_port.clear();
    return Qnil;
}

static VALUE do_input_writer_write(VALUE port_access, VALUE type_name, VALUE rb_typelib_value)
{
    RTT::base::OutputPortInterface& local_port = get_wrapped<RTT::base::OutputPortInterface>(port_access);
    Typelib::Value value = typelib_get(rb_typelib_value);

    orogen_transports::TypelibMarshallerBase* transport = 0;
    RTT::types::TypeInfo* ti = get_type_info(StringValuePtr(type_name));
    if (ti && ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
    {
        transport =
            dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
    }

    if (!transport)
    {
        RTT::base::DataSourceBase::shared_ptr ds =
            ti->buildReference(value.getData());

        local_port.write(ds);
    }
    else
    {
        orogen_transports::TypelibMarshallerBase::Handle* handle =
            transport->createSample();

        transport->setTypelibSample(handle, static_cast<uint8_t*>(value.getData()));
        RTT::base::DataSourceBase::shared_ptr ds =
            transport->getDataSource(handle);
        local_port.write(ds);
        transport->deleteHandle(handle);
    }
    return local_port.connected() ? Qtrue : Qfalse;
}

static VALUE do_local_port_disconnect(VALUE port_access)
{
    RTT::base::PortInterface& local_port = get_wrapped<RTT::base::PortInterface>(port_access);
    local_port.disconnect();
    return Qnil;
}

/*
 * call-seq: connected? => true or false
 *
 * Returns true if this port reader or writer is still connected to a remote
 * port
 */
static VALUE do_local_port_connected(VALUE port_access)
{
    RTT::base::PortInterface& local_port = get_wrapped<RTT::base::PortInterface>(port_access);
    return local_port.connected() ? Qtrue : Qfalse;
}

/* Document-class: Orocos::NotFound
 *
 * This exception is raised every time an Orocos object is required by name,
 * but the object does not exist.
 *
 * See for instance Orocos::TaskContext.get or Orocos::TaskContext#port
 */
/* Document-class: Orocos::Attribute
 *
 * Attributes and properties are in Orocos ways to parametrize the task contexts.
 * Instances of Orocos::Attribute actually represent both at the same time.
 */
/* Document-module: Orocos
 */
namespace RTT
{
    namespace Corba
    {
        extern int loadCorbaLib();
    }
}

static VALUE orocos_load_standard_typekits(VALUE mod)
{
    // load the default toolkit and the CORBA transport
    RTT::types::TypekitRepository::Import(new RTT::types::RealTimeTypekitPlugin);
    RTT::types::TypekitRepository::Import(new RTT::corba::CorbaLibPlugin);
#ifdef HAS_MQUEUE
    RTT::types::TypekitRepository::Import(new RTT::mqueue::MQLibPlugin);
#endif
    //TODO loadCorbaLib();
    return Qnil;
}

static VALUE orocos_load_rtt_typekit(VALUE orocos, VALUE path)
{
    try
    {
        return RTT::plugin::PluginLoader::Instance()->loadLibrary(StringValuePtr(path)) ? Qtrue : Qfalse;
    }
    catch(std::runtime_error e)
    {
        rb_raise(rb_eArgError, e.what());
    }
}

static VALUE orocos_load_rtt_plugin(VALUE orocos, VALUE path)
{
    try
    {
        return RTT::plugin::PluginLoader::Instance()->loadLibrary(StringValuePtr(path)) ? Qtrue : Qfalse;
    }
    catch(std::runtime_error e)
    {
        rb_raise(rb_eArgError, e.what());
    }
}

#ifdef HAS_MQUEUE
static VALUE try_mq_open(VALUE mod)
{
    int this_pid = getpid();
    std::string queue_name = std::string("/orocosrb_") + boost::lexical_cast<std::string>(this_pid);

    mq_attr attributes;
    attributes.mq_flags = 0;
    attributes.mq_maxmsg = 1;
    attributes.mq_msgsize = 1;
    mqd_t setup = mq_open(queue_name.c_str(), O_RDWR | O_CREAT, S_IREAD | S_IWRITE, &attributes);
    if (setup == -1)
        return rb_str_new2(strerror(errno));
    else
    {
        mq_close(setup);
        mq_unlink(queue_name.c_str());
        return Qnil;
    }
}

/* call-seq:
 *   Orocos::MQueue.transportable_type_names => name_list
 *
 * Returns an array of string that are the type names which can be transported
 * over the MQ layer
 */
static VALUE mqueue_transportable_type_names(VALUE mod)
{
    RTT::types::TypeInfoRepository::shared_ptr rtt_types =
        RTT::types::TypeInfoRepository::Instance();

    VALUE result = rb_ary_new();
    vector<string> all_types = rtt_types->getTypes();
    for (vector<string>::iterator it = all_types.begin(); it != all_types.end(); ++it)
    {
        RTT::types::TypeInfo* ti = rtt_types->type(*it);
        vector<int> transports = ti->getTransportNames();
        if (find(transports.begin(), transports.end(), ORO_MQUEUE_PROTOCOL_ID) != transports.end())
            rb_ary_push(result, rb_str_new2(it->c_str()));
    }
    return result;
}
#endif

extern "C" void Init_rorocos_ext()
{
    mOrocos = rb_define_module("Orocos");
    mCORBA  = rb_define_module_under(mOrocos, "CORBA");
    rb_define_singleton_method(mOrocos, "load_standard_typekits", RUBY_METHOD_FUNC(orocos_load_standard_typekits), 0);
    rb_define_singleton_method(mOrocos, "load_rtt_plugin",  RUBY_METHOD_FUNC(orocos_load_rtt_plugin), 1);
    rb_define_singleton_method(mOrocos, "load_rtt_typekit", RUBY_METHOD_FUNC(orocos_load_rtt_typekit), 1);
    rb_define_singleton_method(mOrocos, "registered_type?", RUBY_METHOD_FUNC(orocos_registered_type_p), 1);
    rb_define_singleton_method(mOrocos, "do_typelib_type_for", RUBY_METHOD_FUNC(orocos_typelib_type_for), 1);

    cTaskContext = rb_define_class_under(mOrocos, "TaskContext", rb_cObject);
    rb_const_set(cTaskContext, rb_intern("STATE_PRE_OPERATIONAL"),      INT2FIX(RTT::corba::CPreOperational));
    rb_const_set(cTaskContext, rb_intern("STATE_FATAL_ERROR"),          INT2FIX(RTT::corba::CFatalError));
    rb_const_set(cTaskContext, rb_intern("STATE_EXCEPTION"),            INT2FIX(RTT::corba::CException));
    rb_const_set(cTaskContext, rb_intern("STATE_STOPPED"),              INT2FIX(RTT::corba::CStopped));
    rb_const_set(cTaskContext, rb_intern("STATE_RUNNING"),              INT2FIX(RTT::corba::CRunning));
    rb_const_set(cTaskContext, rb_intern("STATE_RUNTIME_ERROR"),        INT2FIX(RTT::corba::CRunTimeError));

    rb_const_set(mOrocos, rb_intern("TRANSPORT_CORBA"), INT2FIX(ORO_CORBA_PROTOCOL_ID));

#ifdef HAS_MQUEUE
    VALUE mMQueue  = rb_define_module_under(mOrocos, "MQueue");
    rb_const_set(mOrocos, rb_intern("RTT_TRANSPORT_MQ_ID"),    INT2FIX(ORO_MQUEUE_PROTOCOL_ID));
    rb_define_singleton_method(mMQueue, "try_mq_open", RUBY_METHOD_FUNC(try_mq_open), 0);
    rb_define_singleton_method(mMQueue, "transportable_type_names", RUBY_METHOD_FUNC(mqueue_transportable_type_names), 0);
#endif
    
    cPort         = rb_define_class_under(mOrocos, "Port", rb_cObject);
    cOutputPort   = rb_define_class_under(mOrocos, "OutputPort", cPort);
    cInputPort    = rb_define_class_under(mOrocos, "InputPort", cPort);
    cPortAccess   = rb_define_class_under(mOrocos, "PortAccess", rb_cObject);
    cOutputReader = rb_define_class_under(mOrocos, "OutputReader", cPortAccess);
    cInputWriter  = rb_define_class_under(mOrocos, "InputWriter", cPortAccess);
    eNotFound     = rb_define_class_under(mOrocos, "NotFound", rb_eRuntimeError);
    eStateTransitionFailed = rb_define_class_under(mOrocos, "StateTransitionFailed", rb_eRuntimeError);
    eConnectionFailed = rb_define_class_under(mOrocos, "ConnectionFailed", rb_eRuntimeError);

    rb_define_singleton_method(mOrocos, "do_task_names", RUBY_METHOD_FUNC(orocos_do_task_names), 0);
    rb_define_singleton_method(cTaskContext, "do_get", RUBY_METHOD_FUNC(task_context_get), 1);
    rb_define_singleton_method(cTaskContext, "do_get_from_ior", RUBY_METHOD_FUNC(task_context_get_from_ior), 1);
    rb_define_method(cTaskContext, "==", RUBY_METHOD_FUNC(task_context_equal_p), 1);
    rb_define_method(cTaskContext, "do_state", RUBY_METHOD_FUNC(task_context_state), 0);
    rb_define_method(cTaskContext, "do_configure", RUBY_METHOD_FUNC(task_context_configure), 0);
    rb_define_method(cTaskContext, "do_start", RUBY_METHOD_FUNC(task_context_start), 0);
    rb_define_method(cTaskContext, "do_reset_exception", RUBY_METHOD_FUNC(task_context_reset_exception), 0);
    rb_define_method(cTaskContext, "do_stop", RUBY_METHOD_FUNC(task_context_stop), 0);
    rb_define_method(cTaskContext, "do_cleanup", RUBY_METHOD_FUNC(task_context_cleanup), 0);
    rb_define_method(cTaskContext, "do_has_port?", RUBY_METHOD_FUNC(task_context_has_port_p), 1);
    rb_define_method(cTaskContext, "do_has_operation?", RUBY_METHOD_FUNC(task_context_has_operation_p), 1);
    rb_define_method(cTaskContext, "do_property_type_name", RUBY_METHOD_FUNC(task_context_property_type_name), 1);
    rb_define_method(cTaskContext, "do_attribute_type_name", RUBY_METHOD_FUNC(task_context_attribute_type_name), 1);
    rb_define_method(cTaskContext, "do_attribute_names", RUBY_METHOD_FUNC(task_context_attribute_names), 0);
    rb_define_method(cTaskContext, "do_property_names", RUBY_METHOD_FUNC(task_context_property_names), 0);
    rb_define_method(cTaskContext, "do_port", RUBY_METHOD_FUNC(task_context_do_port), 1);
    rb_define_method(cTaskContext, "do_each_port", RUBY_METHOD_FUNC(task_context_each_port), 0);

    rb_define_method(cPort, "connected?", RUBY_METHOD_FUNC(port_connected_p), 0);
    rb_define_method(cPort, "do_disconnect_from", RUBY_METHOD_FUNC(do_port_disconnect_from), 1);
    rb_define_method(cPort, "do_disconnect_all", RUBY_METHOD_FUNC(do_port_disconnect_all), 0);
    rb_define_method(cOutputPort, "do_connect_to", RUBY_METHOD_FUNC(do_port_connect_to), 2);
    rb_define_method(cOutputPort, "do_reader", RUBY_METHOD_FUNC(do_output_port_reader), 3);
    rb_define_method(cInputPort, "do_writer", RUBY_METHOD_FUNC(do_input_port_writer), 2);

    rb_define_method(cPortAccess, "disconnect", RUBY_METHOD_FUNC(do_local_port_disconnect), 0);
    rb_define_method(cPortAccess, "connected?", RUBY_METHOD_FUNC(do_local_port_connected), 0);
    rb_define_method(cOutputReader, "do_read", RUBY_METHOD_FUNC(do_output_reader_read), 3);
    rb_define_method(cOutputReader, "clear", RUBY_METHOD_FUNC(output_reader_clear), 0);
    rb_define_method(cInputWriter, "do_write", RUBY_METHOD_FUNC(do_input_writer_write), 2);

    Orocos_init_CORBA();
    Orocos_init_data_handling(cTaskContext);
    Orocos_init_methods();
}

