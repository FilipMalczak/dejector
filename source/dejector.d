import std.conv : to;
import std.functional : toDelegate;
import std.stdio : writefln;
import std.string : chomp;
import std.traits : fullyQualifiedName, hasMember, moduleName, ParameterTypeTuple;


extern (C) Object _d_newclass(const TypeInfo_Class ci);

private immutable argumentSeparator = ", ";

private string generateGet(T)() {
    immutable nameOfT = fullyQualifiedName!T;
    auto code = "
        Object get(string key, ref Object[string] known) {
            auto instance = cast(T) _d_newclass(T.classinfo);
            known[key] = instance;";


    static if (hasMember!(T, "__ctor")) {
        foreach (type; ParameterTypeTuple!(T.__ctor)) {
            code ~= "import " ~ moduleName!type ~ ";";
        }

        code ~= "instance.__ctor(";

        foreach (type; ParameterTypeTuple!(T.__ctor)) {
            code ~= "this.dej.get!(" ~ fullyQualifiedName!type ~ ")(known)" ~
                argumentSeparator;
        }
        code = chomp(code, argumentSeparator) ~ ");";
    }
    code ~= "return instance; }";
    return code;
}


interface Provider {
    Object get(string key, ref Object[string] known);
}


class ClassProvider(T) : Provider {
    private Dejector dej;
    this(Dejector dejector) {
        this.dej = dejector;
    }
    mixin(generateGet!T);
}


class FunctionProvider : Provider {
    private Object delegate(ref Object[string]) provide;

    this(Object delegate(ref Object[string]) provide) {
        this.provide = provide;
    }

    Object get(string key, ref Object[string] known) {
        auto v = this.provide(known);
        known[key] = v;
        return v;
    }
}


class InstanceProvider : Provider {
    private Object instance;

    this(Object instance) {
        this.instance = instance;
    }

    Object get(string key, ref Object[string] known) {
        known[key] = this.instance;
        return this.instance;
    }
}


private struct Binding {
    string key;
    Provider provider;
    Scope scope_;
}


interface Scope {
    Object get(string key, Provider provider, ref Object[string] known);
}

//todo IMO it's Prototype
class NoScope : Scope {
    Object get(string key, Provider provider, ref Object[string] known) {
        import std.stdio;
        import std.conv;
        writeln("NoScope key "~key~" "~to!string(known), key);
        auto o = provider.get(key, known);
        writeln("RETURN NEW ", to!string(&o), key);
        return o;
    }
}

class Singleton : Scope {
    private Object[string] instances;

    Object get(string key, Provider provider, ref Object[string] known) {
        import std.stdio;
        writeln("Singleton key "~key~" "~to!string(known));
        auto found = key in known;
        if (found){
            writeln("ALREADY KNOWN ", key);
            return known[key];
        }
        if(key !in this.instances) {
            this.instances[key] = provider.get(key, known);
        }
        return this.instances[key];
    }
}


interface Module {
    void configure(Dejector dejector);
}


class Dejector {
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

    void bind(Class, ScopeClass:Scope = NoScope)() {
        this.bind!(Class, Class, ScopeClass);
    }

    void bind(Interface, Class, ScopeClass:Scope = NoScope)() {
        this.bind!(Interface, ScopeClass)(new ClassProvider!Class(this));
    }

    void bind(Interface, ScopeClass:Scope = NoScope)(Provider provider) {
        immutable key = fullyQualifiedName!Interface;
        if(key in this.bindings) {
            throw new Exception("Interface already bound");
        }
        auto scope_ = this.scopes[fullyQualifiedName!ScopeClass];
        this.bindings[key] = Binding(key, provider, scope_);
    }

    void bind(Interface, ScopeClass:Scope = NoScope)(Object delegate(ref Object[string]) provide) {
        this.bind!(Interface, ScopeClass)(new FunctionProvider(provide));
    }

    void bind(Interface, ScopeClass:Scope = NoScope)(Object function(ref Object[string]) provide) {
        this.bind!(Interface, ScopeClass)(toDelegate(provide));
    }
    
    private static Object[string] emptyKnown;

    Interface get(Interface)() {
        Object[string] known;
        return get!(Interface)(known);
    }

    Interface get(Interface)(ref Object[string] known) {
        return get!(Interface, Interface)(known);
    }

    Interface get(Query, Interface)() {
        Object[string] known;
        return get!(Query, Interface)(known);
    }

    Interface get(Query, Interface)(ref Object[string] known) {
        auto binding = this.bindings[fullyQualifiedName!Query];
        immutable key = fullyQualifiedName!Query;
        return cast(Interface) binding.scope_.get(key, binding.provider, known);
    }
}
