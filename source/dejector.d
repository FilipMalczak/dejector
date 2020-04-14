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

private enum isObjectType(T) = is(T == interface) || is(T == class);
private enum isValueType(T) = is(T == struct) || is(T==enum);

string queryString(T)() if (isObjectType!T) {
    return fullyQualifiedName!T;
}

string queryString(T)(T t) if (is(T == struct)) {
    import std.conv: to;
    return moduleName!T~"."~to!string(t);
}

string queryString(T)(T t) if (is(T == enum)) {
    import std.conv: to;
    return fullyQualifiedName!T~"."~to!string(t);
}

class Dejector {
    private struct Binding {
        string key;
        Provider provider;
        Scope scope_;
        
        Object get(){
            return scope_.get(key, provider);
        }
    }
    
    private interface BindingResolver {
        Binding resolve();
    }
    
    private class ExplicitResolver: BindingResolver {
        private Binding binding;
        
        this(Binding binding){
            this.binding = binding;
        }
        
        override Binding resolve(){
            traceWiring("Resolving explicit binding for key "~key);
            return binding;
        }
        
        override string toString(){
            return typeof(this).stringof~"(key="~key~")";
        }
        
        @property
        string key(){
            return binding.key;
        }
    }
    
    private class AliasResolver: BindingResolver {
        private ResolverMapping resolvers;
        private string aliasName;
        private string aliasTarget;
        
        this(ResolverMapping resolvers, string aliasName, string aliasTarget){
            this.resolvers = resolvers;
            this.aliasName = aliasName;
            this.aliasTarget = aliasTarget;
        }
        
        override Binding resolve(){
            traceWiring("Resolving alias "~aliasName~" -> "~aliasTarget);
            return resolvers.backend[aliasTarget].resolve();
        }
        
        override string toString(){
            import std.conv: to;
            return typeof(this).stringof~"("~aliasName~" -> "~aliasTarget~"; {"~to!string(&resolvers)~"})";
        }
        
        BindingAlias toBindingAlias(){
            return BindingAlias(aliasName, aliasTarget);
        }
    }
    
    private class ResolverMapping {
        private BindingResolver[string] backend;
        
        override string toString(){
            import std.conv: to;
            return typeof(this).stringof~"("~to!string(backend)~")";
        }
    }
    
    //todo private; public for debugging
    ResolverMapping resolvers;
    private Scope[string] scopes;

    this(Module[] modules) {
        resolvers = new ResolverMapping();
        this.bindScope!NoScope;
        this.bindScope!Singleton;

        foreach(module_; modules) {
            module_.configure(this);
        }
    }

    this() {
        this([]);
    }
    
    struct BindingAlias {string name; string target;}
    
    @property
    string[] allQueries(){
        return resolvers.backend.keys();
    }
    
    @property
    string[] allConcreteTypeQueries(){
        string[] result;
        foreach (r; resolvers.backend.values()){
            ExplicitResolver r2 = cast(ExplicitResolver) r;
            if (r2 !is null){
                result ~= r2.key;
            }
        }
        return result;
    }
    
    @property
    BindingAlias[] aliasing(){
        BindingAlias[] result;
        foreach (r; resolvers.backend.values()){
            AliasResolver r2 = cast(AliasResolver) r;
            if (r2 !is null){
                result ~= r2.toBindingAlias;
            }
        }
        return result;
    }

    void bindScope(Class)() {
        immutable scopeQuery = queryString!Class();
        if(scopeQuery in this.scopes) {
            throw new DejectorException("Scope "~scopeQuery~" already bound");
        }
        this.scopes[scopeQuery] = new Class();
    }

    void bind(string alias_, string for_) {
        if (alias_ in this.resolvers.backend) {
            throw new DejectorException("Alias "~alias_~" for "~for_~"already bound!");
        }
        this.resolvers.backend[alias_] = new AliasResolver(resolvers, alias_, for_);
    }
    
    void bind(Qualifier)(Qualifier qualifier, string for_) if (isValueType!Qualifier) {
        bind(queryString(qualifier), for_);
    }
    
    void bind(Qualifier)(string for_) if (isObjectType!Qualifier) {
        bind(queryString!Qualifier(), for_);
    }
    
    void bind(Qualifier, Class, ScopeClass:Scope = Singleton)(Qualifier qualifier) if (isValueType!Qualifier) {
        import std.algorithm;
        if (is(Class == class) && !allConcreteTypeQueries.canFind(queryString!Class))
            this.bind!(Class, ScopeClass)();
        bind(queryString(qualifier), queryString!Class);
    }
    
    void bind(Type, Class, ScopeClass:Scope = Singleton)() if (isObjectType!Type && isObjectType!Class) {
        import std.algorithm;
        if (is(Class == class) && !allConcreteTypeQueries.canFind(queryString!Class))
            this.bind!(Class, ScopeClass)();
            
        this.bind!(Type)(queryString!Class());
    }
    
    private void bind(Type)(BindingResolver resolver) if (isObjectType!Type) {
        immutable query = queryString!Type();
        if (query in this.resolvers.backend) {
            throw new DejectorException("Type "~query~" already bound!");
        }
        this.resolvers.backend[query] = resolver;
    }

    void bind(Type, ScopeClass:Scope = Singleton)(Provider provider) if (isObjectType!Type) {
        if (!(queryString!ScopeClass() in this.scopes))
            throw new DejectorException("Unknown scope "~queryString!ScopeClass());
        auto scope_ = this.scopes[queryString!ScopeClass()];
        this.bind!(Type)(new ExplicitResolver(Binding(queryString!Type(), provider, scope_)));
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
        return get!(Type)(queryString!Type());
    }

    Type get(Query, Type)() if (isObjectType!Query) {
        return get!(Type)(queryString!Query());
    }
    
    Type get(Qualifier, Type)(Qualifier qualifier) if (isValueType!Qualifier) {
        return get!(Type)(queryString(qualifier));
    }
    
    private Binding resolveBinding(string query){
        return this.resolvers.backend[query].resolve();
    }
    
    Type get(Type)(string query){
        import std.algorithm: canFind;
        if (!allQueries.canFind(query))
            return null;
        auto binding = resolveBinding(query);
        return cast(Type) binding.get(); 
    }
    
    string resolveQuery(Type)(){
        return resolveQuery(queryString!Type());
    }
    
    string resolveQuery(string query){
        return this.resolvers.backend[query].resolve().key;
    }
}
