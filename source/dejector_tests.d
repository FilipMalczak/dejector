import dejector : Dejector, InstanceProvider, Module, NoScope, Singleton, queryString;

import std.stdio;

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
        
        auto resolved = dejector.resolveQuery!Greeter();
        assert(resolved == queryString!(GreeterImplementation));
        auto byConcrete = dejector.get!GreeterImplementation();
        assert(greeter == byConcrete);
        assert(greeter is byConcrete);
        assert(dejector.allConcreteTypeQueries == ["dejector_tests.GreeterImplementation", "dejector_tests.X", "dejector_tests.User"]);
        assert(dejector.aliasing == [Dejector.BindingAlias("dejector_tests.Greeter", "dejector_tests.GreeterImplementation")]);
        writeln(__LINE__, " X/User/Greeter passed");
    }

    /// InstanceProvider works
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(User)(new InstanceProvider(new User("Jon")));
        assert(dejector.get!User.name == "Jon");
        writeln(__LINE__, " X/User/Greeter passed");
    }

    /// NoScope binding creates new object on every call
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(X, NoScope);

        assert(dejector.get!X() !is dejector.get!X());
        writeln(__LINE__, " X/User/Greeter passed");
    }

    /// Singleton binding always returns the same object
    unittest {
        auto dejector = new Dejector;
        dejector.bind!(X, Singleton);

        assert(dejector.get!X is dejector.get!X);
        writeln(__LINE__, " X/User/Greeter passed");
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

//aliases and qualifiers
version(unittest) {
    class C1 {}

    class C2 {}

    class C3 {}
    
    class C4 {}

    enum E1 { V1, V2 }

    struct S1 { int x = 0; }
   
    class C5 {}

    class ValuesModule: Module {
        void configure(Dejector dejector) {
            dejector.bind!C1;
            dejector.bind("abc", queryString!C1); //todo bind!C1("abc") = alias C1 -> abc
            dejector.bind!(E1, C2)(E1.V1); //todo bind!(E1.V1, C2)
            dejector.bind!(S1, C3)(S1(3));
            dejector.bind!(C5, C4);
        }
    }

    unittest {
        auto dejector = new Dejector([new ValuesModule()]);
        //fixme order may vary
        //fixme hardcoded queryString results
        assert(dejector.aliasing == [
            Dejector.BindingAlias("dejector_tests.E1.V1", "dejector_tests.C2"), 
            Dejector.BindingAlias("dejector_tests.S1(3)", "dejector_tests.C3"), 
            Dejector.BindingAlias("abc", "dejector_tests.C1"), 
            Dejector.BindingAlias("dejector_tests.C5", "dejector_tests.C4")
        ]);
        assert(dejector.allConcreteTypeQueries == [
            "dejector_tests.C1", 
            "dejector_tests.C3", 
            "dejector_tests.C4", 
            "dejector_tests.C2"
        ]);
        assert(dejector.get!Object("abc") is dejector.get!C1); //todo default template param
        assert(dejector.get!(E1, Object)(E1.V1) is dejector.get!C2); //ditto
        assert(dejector.get!(E1, Object)(E1.V2) is null);
        assert(dejector.get!(S1, Object)(S1(3)) is dejector.get!C3); //ditto
        assert(dejector.get!(S1, Object)(S1()) is null);
        assert(dejector.get!(C5, Object) is dejector.get!C4);
        writeln("Values passed");
    }
}

