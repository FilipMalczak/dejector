import std.functional : toDelegate;
import std.meta: staticMap, Alias;
import std.string : join;
import std.traits : fullyQualifiedName, hasMember, moduleName, ParameterTypeTuple, Parameters;

extern (C) Object _d_newclass(const TypeInfo_Class ci);

void traceWiring(T...)(T t){
    version(dejector_trace) {
        import std.stdio: writeln;
        writeln(t);
    }
}

interface Initializer {
    void initialize(Object o);
}

class NullInitializer: Initializer {
    override void initialize(Object o){
        traceWiring("Null initialize instance ", &o);
    }
}

class Initialization {
    Object instance;
    bool performed;
    Initializer initializer;
    
    this(Object instance, bool performed, Initializer initializer){
        this.instance = instance;
        this.performed = performed;
        this.initializer = initializer;
    }
    
    Initialization ensureInitialized (){
        if (!performed){
            traceWiring("Initializing ", &instance);
            performed = true;
            initializer.initialize(instance);
            traceWiring("Initialized ", &instance);
        } {
            traceWiring("Already initialized", &instance);
        }
        return this;
    }
}

interface Provider {
    Initialization get();
}

private string callCtor(T)(){
    string result;
    static foreach (t; Parameters!(T.__ctor)){
        result ~= "import "~moduleName!t~";\n";
    }
    string[] params;
    static foreach (t; Parameters!(T.__ctor)){
        params ~= "this.dej.get!("~fullyQualifiedName!t~")()";
    }
    result ~= "(cast(T) instance).__ctor("~(params.join(", "))~");";
    return result;
}

class ClassInitializer(T): Initializer {
    private Dejector dej;
    this(Dejector dejector) {
        this.dej = dejector;
    }

    override void initialize(Object instance){
        static if (hasMember!(T, "__ctor")) {
            traceWiring("Calling constructor for instance ", &instance, " of type ", fullyQualifiedName!T);
            mixin(callCtor!T());
            traceWiring("Called constructor for ", &instance);
        }
    }
}

class ClassProvider(T) : Provider {
    private Dejector dej;
    this(Dejector dejector) {
        this.dej = dejector;
    }
    
    override Initialization get(){
        traceWiring("Building instance of type ", fullyQualifiedName!T);
        auto instance = cast(T) _d_newclass(T.classinfo);
        traceWiring("Built uninitialized instance ", &instance, " of type ", fullyQualifiedName!T);
        return new Initialization(instance, false, new ClassInitializer!T(dej));
    }
}


class FunctionProvider : Provider {
    private Object delegate() provide;

    this(Object delegate() provide) {
        this.provide = provide;
    }

    Initialization get() {
        return new Initialization(provide(), true, new NullInitializer);
    }
}


class InstanceProvider : Provider {
    private Object instance;

    this(Object instance) {
        this.instance = instance;
    }

    Initialization get() {
        return new Initialization(instance, true, new NullInitializer);
    }
}


interface Scope {
    Object get(string key, Provider provider);
}

//todo IMO it's Prototype
class NoScope : Scope {
    Object get(string key, Provider provider) {
        traceWiring("NoScope for key ", key);
        return provider.get().ensureInitialized.instance;
    }
}

class Singleton : Scope {
    private Object[string] instances;

    Object get(string key, Provider provider) {
        traceWiring("Singleton for key ", key);
        if(key !in this.instances) {
            traceWiring("Not cached for key ", key);
            auto i = provider.get();
            this.instances[key] = i.instance;
            traceWiring("Cached ", key, " with ", &(i.instance));
            i.ensureInitialized;
        } else {
            traceWiring("Already cached ", key);
        }
        traceWiring("Singleton ", key, " -> ", key in instances);
        return this.instances[key];
    }
}


interface Module {
    void configure(Dejector dejector);
}


class Dejector {
    private struct Binding {
        string key;
        Provider provider;
        Scope scope_;
    }

    private Binding[string] bindings;
    private Scope[string] scopes;

    this(Module[] modules) {
        this.bindScope!NoScope;
        this.bindScope!Singleton;

        foreach(module_; modules) {
            module_.configure(this);
        }
    }

    this() {
        this([]);
    }

    void bindScope(Class)() {
        immutable key = fullyQualifiedName!Class;
        if(key in this.scopes) {
            throw new Exception("Scope already bound");
        }
        this.scopes[key] = new Class();
    }

    void bind(Class, ScopeClass:Scope = Singleton)() {
        this.bind!(Class, Class, ScopeClass);
    }

    void bind(Interface, Class, ScopeClass:Scope = Singleton)() {
        this.bind!(Interface, ScopeClass)(new ClassProvider!Class(this));
    }

    void bind(Interface, ScopeClass:Scope = Singleton)(Provider provider) {
        immutable key = fullyQualifiedName!Interface;
        if(key in this.bindings) {
            throw new Exception("Interface already bound");
        }
        auto scope_ = this.scopes[fullyQualifiedName!ScopeClass];
        this.bindings[key] = Binding(key, provider, scope_);
    }

    void bind(Interface, ScopeClass:Scope = Singleton)(Object delegate() provide) {
        this.bind!(Interface, ScopeClass)(new FunctionProvider(provide));
    }

    void bind(Interface, ScopeClass:Scope = Singleton)(Object function() provide) {
        this.bind!(Interface, ScopeClass)(toDelegate(provide));
    }

    Interface get(Interface)() {
        return get!(Interface, Interface)();
    }

    //todo a beature - a bug that is a feature; since there is no Class: Interface declaration
    //in bind signature, it may happen, that we register two unrelated types together
    //that seems like a bug, but actually we can implement qualifiers thanks to
    //that, so I also call it a feature and extend API to allow for that
    Interface get(Query, Interface)() {
        auto binding = this.bindings[fullyQualifiedName!Query];
        immutable key = fullyQualifiedName!Query;
        return cast(Interface) binding.scope_.get(key, binding.provider);
    }
}
