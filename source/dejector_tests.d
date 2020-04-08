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
                dejector.bind!(User)(function() { return new User("root"); });
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

import std.stdio;

///Circular dependencies
version(unittest){
    import std.conv;

    class A {
        B _b;
        
        this(B b){
            _b = b;
        }
    }

    class B {
        A _a;
        
        this(A a){
            _a = a;
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
        assert(a !is null);
        assert(a._b !is null);
        assert(a._b._a !is null);
        assert(a._b._a is a);
        
        auto b = dejector.get!B;
        assert(b !is null);
        assert(b._a !is null);
        assert(b._a._b !is null);
        assert(b._a._b is b);
        writeln("A/B passed");
    }
    
    class X1 {
        X2 x2;
        X3 x3;
        
        this(X2 x2, X3 x3){
            this.x2 = x2;
            this.x3 = x3;
        }
    }
    
    class X2 {
        X3 x3;
        X5 x5;
        
        this(X3 x3, X5 x5){
            this.x3 = x3;
            this.x5 = x5;
        }
    }
    
    class X3 {
        X4 x4;
        X1 x1;
        
        this(X4 x4, X1 x1){
            this.x4 = x4;
            this.x1 = x1;
        }
    }
    
    class X4 {
        X5 x5;
        X2 x2;
        
        this(X5 x5, X2 x2){
            this.x5 = x5;
            this.x2 = x2;
        }
    }
    
    class X5 {
        X3 x3;
        
        this(X3 x3){
            this.x3 = x3;
        }
    }
    
    class XModule: Module {
        override void configure(Dejector dejector){
            dejector.bind!X1;
            dejector.bind!X2;
            dejector.bind!X3;
            dejector.bind!X4;
            dejector.bind!X5;
        }
    }
    
    unittest {
        auto dejector = new Dejector([new XModule()]);
        auto x1 = dejector.get!(X1)();
        auto x2 = dejector.get!(X2)();
        auto x3 = dejector.get!(X3)();
        auto x4 = dejector.get!(X4)();
        auto x5 = dejector.get!(X5)();
        assert(x1 !is null);
        assert(x2 !is null);
        assert(x3 !is null);
        assert(x4 !is null);
        assert(x5 !is null);
        
        assert(x1.x2 is x2);
        assert(x1.x3 is x3);
        
        assert(x2.x3 is x3);
        assert(x2.x5 is x5);
        
        assert(x3.x4 is x4);
        assert(x3.x1 is x1);
        
        assert(x4.x5 is x5);
        assert(x4.x2 is x2);
        
        assert(x5.x3 is x3);
        
        writeln("X1-X5 passed");
    }
    
    class A1 {
        A2 a2;
        
        this(A2 a2){
            this.a2 = a2;
        }
    }
    
    class A2 {
        A3 a3;
        
        this(A3 a3){
            this.a3 = a3;
        }
    }
    
    class A3 {
        A1 a1;
        
        this(A1 a1){
            this.a1 = a1;
        }
    }
    
    class AModule: Module {
        override void configure(Dejector dejector){
            dejector.bind!A1;
            dejector.bind!A2;
            dejector.bind!A3;
        }
    }
    
    unittest {
        auto dejector = new Dejector([new AModule()]);
        auto a1 = dejector.get!A1;
        auto a2 = dejector.get!A2;
        auto a3 = dejector.get!A3;
        assert(a1 !is null);
        assert(a2 !is null);
        assert(a3 !is null);
        assert(a1.a2 is a2);
        assert(a2.a3 is a3);
        assert(a3.a1 is a1);
        assert(dejector.get!A1);
        writeln("A1-A3 passed");
    }
}
