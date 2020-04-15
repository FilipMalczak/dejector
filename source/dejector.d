import std.functional : toDelegate;
import std.meta: staticMap, Alias;
import std.string : join;
import std.traits : fullyQualifiedName, hasMember, moduleName, ParameterTypeTuple, Parameters;
import std.algorithm: canFind, map, remove;

import optional;

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
    Initialization get(Dejector dejector);
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
    //todo tracing dejector instance here could be actually useful
    override Initialization get(Dejector dejector){
        traceWiring("Building instance of type ", fullyQualifiedName!T);
        auto instance = cast(T) _d_newclass(T.classinfo);
        traceWiring("Built uninitialized instance ", &instance, " of type ", fullyQualifiedName!T);
        return new Initialization(instance, false, new ClassInitializer!T(dejector));
    }
}


class FunctionProvider : Provider {
    private Object delegate(Dejector) provide;

    this(Object delegate(Dejector) provide) {
        this.provide = provide;
    }

    Initialization get(Dejector dejector) {
        return new Initialization(provide(dejector), true, new NullInitializer);
    }
}


class InstanceProvider : Provider {
    private Object instance;

    this(Object instance) {
        this.instance = instance;
    }

    Initialization get(Dejector dejector) {
        return new Initialization(instance, true, new NullInitializer);
    }
}

mixin template DefaultScope(bool onAttached=true, bool onDetached=true){
    Dejector context;

    void onScopeInit(Dejector scopeContext) {
        context = scopeContext;
    }
    static if (onAttached)
        void onParentAttached() {}
    static if (onDetached)
        void onParentDetaching() {}
}

interface Scope {
    Object get(string key, Provider provider);
    //just after instance creation
    void onScopeInit(Dejector scopeContext);
    //every time parent dejector changes from null to non-null
    void onParentAttached();
    //every time parent dejector changes from non-null to null
    void onParentDetaching();
}

class NoScope : Scope {
    mixin DefaultScope;
    Object get(string key, Provider provider) {
        traceWiring("NoScope for key ", key);
        return provider.get(context).ensureInitialized.instance;
    }
}

class Singleton : Scope {
    mixin DefaultScope!(true, false);
    private Object[string] instances;

    Object get(string key, Provider provider) {
        traceWiring("Singleton for key ", key);
        if(key !in this.instances) {
            traceWiring("Not cached for key ", key);
            auto i = provider.get(context);
            this.instances[key] = i.instance;
            traceWiring("Cached ", key, " with ", &(i.instance));
            i.ensureInitialized;
        } else {
            traceWiring("Already cached ", key);
        }
        traceWiring("Singleton ", key, " -> ", key in instances);
        return this.instances[key];
    }
    
    void onParentDetaching(){
        Object[string] newInstances;
        instances = newInstances;
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
    alias ScopeResolver = Optional!Scope delegate(string);

    private struct Binding {
        string key;
        Provider provider;
        string scopeKey;
        
        Object get(ScopeResolver resolver){
            auto scope_ = resolver(scopeKey);
            if (scope_.empty)
                throw new DejectorException("Cannot resolve scope key "~scopeKey);
            return scope_.front().get(key, provider);
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
    
    private string name;
    private ResolverMapping resolvers;
    private Scope[string] scopes;
    private Dejector _parent;
    private Dejector[] _children;

    this(Module[] modules) {
        import std.conv:to;
        import std.uuid: randomUUID;
        name = to!string(randomUUID());
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
    
    override string toString(){
        import std.conv:to;
        return typeof(this).stringof~
                    "(name="~name~
                    ", resolvers.length="~to!string(resolvers.backend.length)~
                    ", concreteTypes.length="~to!string(allConcreteTypeQueries.length)~
                    ", parent="~to!string(_parent)~
                    ")";
    }
    
    @property
    Dejector parent(){
        return _parent;
    }
    
    @property
    void parent(Dejector newParent){
        if (_parent !is newParent) {
            detachParent();
            if (newParent !is null){
                attachParent(newParent);
            }
        }
    }
    
    //works the same way whether parent was null or not; if it was non-null, all the callbacks are called
    void detachParent(){
        if (_parent !is null) {
            onParentDetaching();
            //fixme jesus, there has got to be a better way to remove an element, hasnt it?
            Dejector[] newChildren;
            foreach (c; _parent._children)
                if (c !is this)
                    newChildren ~= c;
            _parent._children = newChildren;
        }
        _parent = null;
    }
    
    // can assume that that really is NEW parent, previous one was null and yet previous was fully detached
    private void attachParent(Dejector newParent){
        checkCyclicRelationship(newParent);
        _parent = newParent;
        _parent._children ~= this;
        onParentAttached();
    }
    
    private void checkCyclicRelationship(Dejector d){
        Dejector looped = d;
        while (looped.parent !is null) {
            if (looped.parent is this) { //todo could count loop runs and show it in exception too
                import std.conv: to;
                throw new DejectorException("Setting this parent would result in cyclic parent relationship (this="~to!string(this)~", proposedParent="~to!string(d)~")");
            }
            looped = looped.parent;
        }
    }
    
    protected void onParentAttached(){
        foreach (s; scopes.values)
            s.onParentAttached();
        thisMayHaveChanged();
    }
    
    protected void onParentDetaching(){
        foreach (s; scopes.values)
            s.onParentDetaching();
        thisMayHaveChanged();
    }
    
    private void thisMayHaveChanged(){
        foreach (c; _children){
            c.detachParent();
            c.attachParent(this);
        }
    }
    
    struct BindingAlias {string name; string target;}
    
    @property
    string[] allNonInheritedQueries(){
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
    
    //todo shadowedQueries, inheritedQueries, introducedQueried
    
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
    
    //todo shadowed/inherited/introduced aliasing?

    void bindScope(Class: Scope)() {
        immutable scopeQuery = queryString!Class();
        if(scopeQuery in this.scopes) {
            throw new DejectorException("Scope "~scopeQuery~" already bound");
        }
        auto newScope = new Class();
        newScope.onScopeInit(this);
        this.scopes[scopeQuery] = newScope;
    }
    
    private Optional!Scope findScope(string key){
        if (key in scopes)
            return scopes[key].some;
        if (_parent !is null){
            return _parent.findScope(key);
        } else {
            return no!Scope;
        }
    }
    
    private void bind(string query, BindingResolver resolver, lazy string exc){
        if (query in this.resolvers.backend) {
            throw new DejectorException(exc);
        }
        this.resolvers.backend[query] = resolver;
    }
    
    private void bind(Type)(BindingResolver resolver) if (isObjectType!Type) {
        immutable query = queryString!Type();
        bind(query, resolver, "Type "~query~" already bound!");
    }

    void bind(string alias_, string for_) {
        traceWiring("Binding alias "~alias_~" -> "~for_);
        bind(alias_, new AliasResolver(resolvers, alias_, for_), "Alias "~alias_~" for "~for_~"already bound!");
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

    void bind(Type, ScopeClass:Scope = Singleton)(Provider provider) if (isObjectType!Type) {
        if (!(queryString!ScopeClass() in this.scopes))
            throw new DejectorException("Unknown scope "~queryString!ScopeClass());
        traceWiring("Binding type "~queryString!Type~" explicitly");
        this.bind!(Type)(new ExplicitResolver(Binding(queryString!Type(), provider, queryString!ScopeClass)));
    }
    
    void bind(Class, ScopeClass:Scope = Singleton)() if (is(Class == class)){
        this.bind!(Class, ScopeClass)(new ClassProvider!Class);
    }
    
    void bind(Type, ScopeClass:Scope = Singleton)(Object delegate(Dejector) provide) if (isObjectType!Type) {
        this.bind!(Type, ScopeClass)(new FunctionProvider(provide));
    }

    void bind(Type, ScopeClass:Scope = Singleton)(Object function(Dejector) provide) if (isObjectType!Type) {
        this.bind!(Type, ScopeClass)(toDelegate(provide));
    }
    
    private Optional!BindingResolver findBindingResolver(string query){
        traceWiring("Looking for binding resolver for "~query);
        if (query in this.resolvers.backend){
            traceWiring("Found it locally");
            return this.resolvers.backend[query].some;
        }
        if (_parent !is null) {
            traceWiring("Delegating to parent");
            return _parent.findBindingResolver(query);
        }
        traceWiring("Couldn't find at all");
        return no!BindingResolver;
    }
    
    private Optional!Binding resolveBinding(string query){
        return findBindingResolver(query).map!((x) => x.resolve()).toOptional;
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
    
    Type get(Type)(string query){
        auto binding = resolveBinding(query);
        if (binding.empty)
            return null;
        return cast(Type) binding.front().get(toDelegate(&this.findScope)); 
    }
    
    Optional!string resolveQuery(Type)(){
        return resolveQuery(queryString!Type());
    }
    
    Optional!string resolveQuery(string query){
        return resolveBinding(query).map!(x => x.key).toOptional;
    }
}
