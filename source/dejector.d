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

class DejectorException: Exception {
    this(string msg = null, Throwable next = null) { 
        super(msg, next);
    }
    this(string msg, string file, size_t line, Throwable next = null) {
        super(msg, file, line, next);
    }
}

class Dejector {
    private enum isObjectType(T) = is(T == interface) || is(T == class);
    private enum isValueType(T) = is(T == struct) || is(T==enum);
    template key(alias T) {
        static if (isObjectType!T){
            enum key = fullyQualifiedName!T;
        } else {
            static if (typeof(T).isValueType)
                enum key = moduleName!T~"."~T;
            else 
                static assert(false, "Only object types or values can be keys");
        } 
    }
    private struct Binding {
        string key;
        Provider provider;
        Scope scope_;
    }
    
    alias BindingResolver = Binding delegate();
    
    private BindingResolver[string] resolvers;
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
        immutable key = key!Class;
        if(key in this.scopes) {
            throw new DejectorException("Scope "~key~" already bound");
        }
        this.scopes[key] = new Class();
    }

    void bind(string alias_, string for_, bool lazy_=true) {
        if (alias_ in this.resolvers) {
            throw new DejectorException("Alias "~alias_~" for "~for_~"already bound!");
        }
        if (lazy_){
            this.resolvers[alias_] = () => resolveBinding(for_);
        } else {
            auto val = resolveBinding(for_);
            this.resolvers[alias_] = () => val;
        }
    }
    
    void bind(Qualifier)(Qualifier qualifier, string for_) if (isValueType!Qualifier) {
        bind(key!qualifier, for_);
    }
    
    void bind(Qualifier)(string for_) if (isObjectType!Qualifier) {
        bind(key!Qualifier, for_);
    }
    
    void bind(Type, Class, ScopeClass:Scope = Singleton)() if (isObjectType!Type && isObjectType!Class) {
        static if (is(Class == class))
            this.bind!(Class, ScopeClass)();
        this.bind!(Type)(() => resolveBinding(key!Class));
    }
    
    private void bind(Type)(BindingResolver resolver) if (isObjectType!Type) {
        immutable key = key!Type;
        if (key in this.resolvers) {
            throw new DejectorException("Type "~key~" already bound!");
        }
        this.resolvers[key] = resolver;
    }

    void bind(Type, ScopeClass:Scope = Singleton)(Provider provider) if (isObjectType!Type) {
        if (!(key!ScopeClass in this.scopes))
            throw new DejectorException("Unknown scope "~key!ScopeClass);
        auto scope_ = this.scopes[key!ScopeClass];
        this.bind!(Type)(() => Binding(key!Type, provider, scope_));
    }
    
    void bind(Class, ScopeClass:Scope = Singleton)() if (is(Class == class)){
        this.bind!(Class, ScopeClass)(new ClassProvider!Class(this));
    }
    
    void bind(Type, ScopeClass:Scope = Singleton)(Object delegate() provide) if (isObjectType!Type) {
        this.bind!(Type, ScopeClass)(new FunctionProvider(provide));
    }

    void bind(Type, ScopeClass:Scope = Singleton)(Object function() provide) if (isObjectType!Type) {
        this.bind!(Type, ScopeClass)(toDelegate(provide));
    }

    Type get(Type)() {
        return get!(Type)(key!Type);
    }

    Type get(Query, Type)() {
        return get!(Type)(key!Query);
    }
    
    private Binding resolveBinding(string query){
        return this.resolvers[query]();
    }
    
    Type get(Type)(string query){
        auto binding = resolveBinding(query);
        return cast(Type) binding.scope_.get(query, binding.provider); 
    }
    
    string resolveQuery(string query){
        return this.resolvers[query]().key;
    }
}
