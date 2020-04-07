import dejector : Dejector, InstanceProvider, Module, NoScope, Singleton;

version(unittest) {
    class X {}

    class User {
        string name;
        this(string name) {
            this.name = name;
        }
    }

    interface Greeter {
        string greet();
    }

    class GreeterImplementation : Greeter {
        this(X x) {}
        string greet() { return "Hello!"; }
    }

    unittest {
        class MyModule : Module {
            void configure(Dejector dejector) {
                dejector.bind!(X);
                dejector.bind!(Greeter, GreeterImplementation);
                dejector.bind!(User)(function(ref Object[string] k) { return new User("root"); });
            }
        }

        auto dejector = new Dejector([new MyModule()]);

        auto greeter = dejector.get!Greeter;
        assert(greeter.greet == "Hello!");

        auto user = dejector.get!User;
        assert(user.name == "root");
    }

    /// InstanceProvider works
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(User)(new InstanceProvider(new User("Jon")));
        assert(dejector.get!User.name == "Jon");
    }

    /// NoScope binding creates new object on every call
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(X, NoScope);

        assert(dejector.get!X() !is dejector.get!X());
    }

    /// Singleton binding always returns the same object
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(X, Singleton);

        assert(dejector.get!X is dejector.get!X);
    }
}

///Circular dependencies
version(unittest){
    import std.conv;

    class A {
        B _b;
        
        this(B b){
            _b = b;
        }
        
        override string toString(){
            return "A(b@"~to!string(&_b)~")";
        }
    }

    class B {
        A _a;
        
        this(A a){
            _a = a;
        }
        
        override string toString(){
            return "B(a@"~to!string(&_a)~")";
        }
    }

    class CircularModule : Module {
        void configure(Dejector dejector) {
            dejector.bind!(A, Singleton);
            dejector.bind!(B, Singleton);
        }
    }

    unittest {
        auto dejector = new Dejector([new CircularModule()]);

        auto a = dejector.get!A;
        import std.stdio;
        writeln(a, "@"~to!string(&a));
        writeln(a._b, "@"~to!string(&(a._b)));
        writeln(a._b._a);
        assert(a !is null);
        assert(a._b !is null);
        assert(a._b._a !is null);
        assert(a._b._a is a); //todo check comparison
    }
}
