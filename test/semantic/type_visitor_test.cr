require "../test_helper"

module Runic
  class Semantic
    class TypeVisitorTest < Minitest::Test
      def setup
        require_corelib
      end

      def test_infers_integer_literal_type
        assert_type "i32", visit("1")
        assert_type "i64", visit("1126516251752")
        assert_type "i128", visit("876121246541126516251752")

        assert_type "i32", visit("0o1")
        assert_type "i64", visit("0o777777777777777777777")
        assert_type "i128", visit("0o1777777777777777777777777777777777777777777")

        assert_type "u32", visit("0xff")
        assert_type "u64", visit("0x1234567890")
        assert_type "u128", visit("0x1234567890abcdef01234")

        assert_type "u32", visit("0b1")
        assert_type "u64", visit("0b#{"1" * 60}")
        assert_type "u128", visit("0b#{"1" * 120}")
      end

      def test_validates_integer_literals
        {% for suffix, num in {
            "i8" => "12",
            "i16" => "3276",
            "i32" => "214748364",
            "i64" => "922337203685477580",
            "i128" => "17014118346046923173168730371588410572",
          }
        %}
          visit("{{num.id}}7_{{suffix.id}}")
          visit("-{{num.id}}8_{{suffix.id}}")
          assert_raises(SemanticError) { visit("{{num.id}}8_{{suffix.id}}") }
          assert_raises(SemanticError) { visit("-{{num.id}}9_{{suffix.id}}") }
        {% end %}

        {% for suffix, num in {
            "u8" => "25",
            "u16" => "6553",
            "u32" => "429496729",
            "u64" => "1844674407370955161",
            "u128" => "34028236692093846346337460743176821145",
          }
        %}
          visit("{{num.id}}5_{{suffix.id}}")
          assert_raises(SemanticError) { visit("-1_{{suffix.id}}") }
          assert_raises(SemanticError) { visit("{{num.id}}6_{{suffix.id}}") }
        {% end %}
      end

      def test_shadows_variable_when_its_underlying_type_changes
        visit_each("a = 1; a = 2.0; b = a; a = 123_u64") do |node, index|
          case index
          when 0
            assert_type "i32", node
            assert_type "i32", node.as(AST::Assignment).lhs  # infers 'a'
          when 1
            assert_type "f64", node
            assert_type "f64", node.as(AST::Assignment).lhs  # 'a' is shadowed
          when 2
            assert_type "f64", node
            assert_type "f64", node.as(AST::Assignment).rhs  # 'a' refers to the tmp variable (not the shadowed)
          when 3
            assert_type "u64", node
            assert_type "u64", node.as(AST::Assignment).rhs  # 'a' is shadowed again
          else
             raise "unreachable"
          end
        end
      end

      def test_shadows_variable_for_current_scope
        source = <<-RUNIC
        a = 1

        if true
          a = 2.0
        end

        a
        RUNIC
        visit_each(source) do |node, index|
          assert_type "i32", node if index == 2
        end
      end

      def test_types_constants
        assert_type "i32", register("FOO = 1")
        assert_type "i32", visit("BAR = FOO")
        assert_raises(SemanticError) { visit("SOME = UNKNOWN") }
        assert_raises(SemanticError) { visit("value = WHAT") }
        assert_raises(SemanticError) { visit("2 + INCREMENT") }
      end

      def test_types_references
        assert_type "i32", visit("foo = 1")
        assert_raises(SemanticError) { visit("*foo") }

        assert_type "i32*", visit("bar = &foo")
        assert_type "i32", visit("*bar")
        assert_raises(SemanticError) { visit("**bar") }

        assert_type "i32**", visit("baz = &bar")
        assert_type "i32*", visit("*baz")
        assert_type "i32", visit("**baz")
        assert_raises(SemanticError) { visit("***baz") }

        assert_type "i32***", visit("mor = &baz")
        assert_type "i32**", visit("*mor")
        assert_type "i32*", visit("**mor")
        assert_type "i32", visit("***mor")
        assert_raises(SemanticError) { visit("****mor") }
      end

      def test_types_math_binary_expressions
        %w(+ - * ** // % %%).each do |op|
          %w(i u).each do |sign|
            %w(8 16 32 64 128).each do |bit|
              ty = "#{sign}#{bit}"
              assert_type ty, visit("1_#{ty} #{op} 2_#{ty}")
            end
          end

          %w(32 64).each do |bit|
            ty = "f#{bit}"
            assert_type ty, visit("1_#{ty} #{op} 2_#{ty}")
          end
        end

        # division always returns a float
        assert_type "f64", visit("1 / 2")
        assert_type "f64", visit("1_f64 / 2_f64")
        assert_type "f32", visit("1_f32 / 2_f32")
      end

      def test_casts_untyped_literal_in_binary_expressions
        assert_type "i8", visit("1_i8 + 2")
        assert_type "i16", visit("2 + 2_i16")
        assert_type "f64", visit("1_f64 + 2")
        assert_type "f32", visit("1 + 2_f32")
        assert_type "u64", visit("102901920109_u64 + 2")
        assert_raises(SemanticError) { visit("1_u8 + 256") }
        assert_raises(SemanticError) { visit("1_i16 + 32768") }
      end

      def test_types_bitwise_binary_expressions
        # bitwise operators
        %w(& | ^ << >>).each do |op|
          %w(i u).each do |sign|
            %w(8 16 32 64 128).each do |bit|
              ty = "#{sign}#{bit}"
              assert_type ty, visit("1_#{ty} #{op} 2_#{ty}")
            end
          end
        end
      end

      def test_types_logical_binary_expressions
        # TODO: || and && for non bool types
        %w(== != || &&).each do |op|
          assert_type "bool", visit("true #{op} false")
          # assert_type "bool", visit("true #{op} 2")
          # assert_type "bool", visit("true #{op} 2.0")
          # assert_type "bool", visit("2 #{op} false")
        end

        %w(== != <=> < <= > >=).each do |op|
          rty = (op == "<=>") ? "i32" : "bool"

          %w(i u).each do |sign|
            %w(8 16 32 64 128).each do |bit|
              ty = "#{sign}#{bit}"
              assert_type rty, visit("1_#{ty} #{op} 2_#{ty}")
            end
          end
        end
      end

      def test_recursively_types_binary_expressions
        node = visit("a = 1 * (2 + 4)").as(AST::Assignment)
        assert_type "i32", node                          # whole expression
        assert_type "i32", node.lhs                      # variable 'a'
        assert_type "i32", node.rhs                      # value
        assert_type "i32", node.rhs.as(AST::Binary).rhs  # 2 + 4
      end

      def test_types_unary_expressions
        assert_type "i32", visit("-(123))")
        assert_type "bool", visit("!123)")
        assert_type "u8", visit("~1_u8)")
        assert_type "i32", visit("~1_i32)")
        assert_raises(SemanticError) { visit("~false)") }
        assert_raises(SemanticError) { visit("~1.0)") }
        assert_raises(SemanticError) { visit("-true)") }
      end

      def test_recursively_types_unary_expressions
        node = visit("!!123)")
        assert_type "bool", node
        assert_type "bool", node.as(AST::Unary).expression
      end

      def test_types_calls
        node = register("def add(a : int, b : float) a.to_f + b; end")
        assert_type "f64", node.as(AST::Function)

        node = visit("add(1, add(2, 3.2))")
        assert_type "f64", node
        assert_types ["i32", "f64"], node.as(AST::Call).args
      end

      def test_validates_call_arguments
        register("def add(a : int, b : float) a.to_f + b; end")

        # wrong number of args:
        assert_raises(SemanticError) { visit("add()") }
        assert_raises(SemanticError) { visit("add(1)") }
        assert_raises(SemanticError) { visit("add(1, 2.0, 3)") }

        # incompatible types:
        assert_raises(SemanticError) { visit("add(1.0, 2.0)") }
        assert_raises(SemanticError) { visit("add(add(1, 2.0), 2.0)") }

        # automatic cast of literals:
        node = visit("add(1, 2)").as(AST::Call)

        arg = node.args[0].as(AST::Integer)
        assert_type "i32", arg
        assert_equal "1", arg.value

        arg = node.args[1].as(AST::Float)
        assert_type "f64", arg
        assert_equal "2", arg.value

        # no automatic cast of variables:
        assert_raises(SemanticError) { visit_each("b = 2; add(1, b)") {} }
      end

      def test_types_stack_constructor_calls
        register("struct Foo; end")

        node = visit("Foo()").as(AST::Call)
        assert_type "Foo", node
        assert_type "Foo*", node.receiver
        assert node.constructor?
        assert_nil node.prototype

        point = register <<-RUNIC
        struct Point
          @x : i32
          @y : i32

          def initialize(x : i32, y : i32)
            @x = x
            @y = y
          end
        end
        RUNIC

        node = visit("Point(1, 2)").as(AST::Call)
        assert_type "Point", node
        assert_type "Point*", node.receiver
        assert node.constructor?

        assert_equal node.prototype, point.as(AST::Struct)
          .method("initialize").as(AST::Function)
          .prototype
      end

      def test_expands_default_arguments_in_calls
        register("def add(a : i32, b = 0.0); end")

        # use defined:
        node = visit("add(1, 2.0)").as(AST::Call)
        assert_equal ["i32", "f64"], node.args.map(&.as(AST::Number).type.name)
        assert_equal ["1", "2.0"], node.args.map(&.as(AST::Number).value)

        # use default:
        node = visit("add(1)").as(AST::Call)
        assert_equal ["i32", "f64"], node.args.map(&.as(AST::Number).type.name)
        assert_equal ["1", "0.0"], node.args.map(&.as(AST::Number).value)

        # automatic cast:
        node = visit("add(3, 4)").as(AST::Call)
        assert_equal ["i32", "f64"], node.args.map(&.as(AST::Number).type.name)
        assert_equal ["3", "4"], node.args.map(&.as(AST::Number).value)

        ex = assert_raises(SemanticError) { visit("add()") }
        assert_match "wrong number of arguments for 'add' (given 0, expected 1..2)", ex.message

        ex = assert_raises(SemanticError) { visit("add(3, false)") }
        assert_match "wrong type for argument 'b' of function 'add' (given bool, expected f64)", ex.message

        # named arguments:
        node = visit("add(1, b: 5)").as(AST::Call)
        assert_equal ["i32", "f64"], node.args.map(&.as(AST::Number).type.name)
        assert_equal ["1", "5"], node.args.map(&.as(AST::Number).value)

        node = visit("add(b: 5, a: 2)").as(AST::Call)
        assert_equal ["i32", "f64"], node.args.map(&.as(AST::Number).type.name)
        assert_equal ["2", "5"], node.args.map(&.as(AST::Number).value)
      end

      def test_reindexes_keyword_arguments_in_calls
        register("def incr(by : int, to : int); end")

        node = visit("incr(1, 5)").as(AST::Call)
        assert_equal ["1", "5"], node.args.map(&.as(AST::Number).value)

        node = visit("incr(1, to: 5)").as(AST::Call)
        assert_equal ["1", "5"], node.args.map(&.as(AST::Number).value)

        node = visit("incr(by: 1, to: 5)").as(AST::Call)
        assert_equal ["1", "5"], node.args.map(&.as(AST::Number).value)

        node = visit("incr(to: 5, by: 1)").as(AST::Call)
        assert_equal ["1", "5"], node.args.map(&.as(AST::Number).value)

        ex = assert_raises(SemanticError) { visit("incr(1, to: 2, by: 1)") }
        assert_match "wrong number of arguments for 'incr' (given 3, expected 2)", ex.message

        ex = assert_raises(SemanticError) { visit("incr(1, by: 1)") }
        assert_match "missing argument 'to' for 'incr'", ex.message
      end

      def test_validates_def_return_type
        ex = assert_raises(SemanticError) { visit("def add(a : int) : int; 1.0; end") }
        assert_match "must return i32 but returns f64", ex.message

        assert_type "void", visit("def add(a : int); end")
        assert_type "void", visit("def foo(a : int) : void; 1.0; end")
      end

      def test_validates_def_default_args
        # can cast floats/ints to float:
        visit("def bar(a : f64 = 1.0); end")
        visit("def bar(a : f32 = 9223372036854775807); end")
        visit("def bar(a : f64 = 1_f32); end")

        # can cast ints to int (if fits):
        visit("def bar(a : int = 123); end")
        visit("def bar(a : int = 123_i64); end")
        assert_raises(SemanticError) { visit("def bar(a : int = 9223372036854775807); end") }

        # can't cast incompatible types:
        assert_raises(SemanticError) { visit("def bar(a : int = false); end") }
        assert_raises(SemanticError) { visit("def bar(a : int = 1.0); end") }
      end

      def test_validates_primitive_functions
        assert_type "i32", visit("#[primitive]\ndef foo : int; end")

        ex = assert_raises(SemanticError) { visit("#[primitive]\ndef foo; end") }
        assert_match "must specify a return type", ex.message
      end

      #def test_validates_previous_definitions
      #  register("def add(a : int, b : float); a.to_f + b; end")

      #  # mismatch: arg count
      #  ex = assert_raises(ConflictError) do
      #    register("def add(a : int, b : float, c : i8) : float; b; end")
      #  end
      #  assert_match "doesn't match previous definition", ex.message

      #  # mismatch: arg type
      #  ex = assert_raises(ConflictError) do
      #    register("def add(a : int, b : int) : f64; 1.0_f64; end")
      #  end
      #  assert_match "doesn't match previous definition", ex.message

      #  # mismatch: return type
      #  ex = assert_raises(ConflictError) do
      #    register("def add(a : int, b : float) : int; a; end")
      #  end
      #  assert_match "doesn't match previous definition", ex.message
      #end

      def test_types_if_expressions
        assert_type "void", visit("if true; 1; end")
        assert_type "i32", visit("if false; 1; else; 2; end")
        assert_type "f64", visit("if false; 123.456; else; 789.1; end")
        assert_type "void", visit("if true; 1; else; 789.1; end")
      end

      def test_types_unless_expressions
        assert_type "void", visit("if true; 1; end")
      end

      def test_types_while_expressions
        assert_type "void", visit("while true; 1; end")
      end

      def test_types_until_expressions
        assert_type "void", visit("until true; 1; end")
      end

      def test_types_case_expressions
        assert_type "void", visit("case 1; when 1; 2.0; end")
        assert_type "void", visit("case 1; when 1; 1.0; when 2; 2.0; end")
        assert_type "void", visit("case 1; when 1; 1_u8; else; 2_u16; end")
        assert_type "u8", visit("case 1; when 1; 1_u8; else; 3_u8; end")
        assert_type "f64", visit("case 1; when 1; 1.0; when 2; 2.0; else; 3.0; end")
      end

      def test_validates_flow_conditions
        register("def foo() : void; 123; end")
        assert_raises(SemanticError) { visit("if foo(); 1; end") }
        assert_raises(SemanticError) { visit("unless foo(); 1; end") }
        assert_raises(SemanticError) { visit("while foo(); 1; end") }
        assert_raises(SemanticError) { visit("until foo(); 1; end") }
        assert_raises(SemanticError) { visit("case foo(); when 1; end") }
        assert_raises(SemanticError) { visit("case 1; when foo(); end") }
      end

      def test_flow_expressions_have_inner_scopes
        assert_raises(SemanticError) { visit_each("if 1; foo = 1; end; foo") {} }
        assert_raises(SemanticError) { visit_each("unless 1; foo = 1; end; foo") {} }
        assert_raises(SemanticError) { visit_each("while 1; foo = 1; end; foo") {} }
        assert_raises(SemanticError) { visit_each("until 1; foo = 1; end; foo") {} }
        assert_raises(SemanticError) { visit_each("case 1; when 2; foo = 1; end; foo") {} }
      end

      def test_types_struct_variables_and_methods
        node = visit(<<-RUNIC).as(AST::Struct)
        struct Foo
          @bar : i32
          @baz : f64

          def initialize(bar : i32, baz : f64)
            @bar = bar
            @baz = baz
          end

          def bar; @bar; end
          def baz; @baz; end
        end
        RUNIC

        assert_type "i32", node.variables[0]
        assert_type "f64", node.variables[1]
        assert_type "void", node.methods.find { |m| m.name == "initialize" }
        assert_type "i32", node.methods.find { |m| m.name == "bar" }
        assert_type "f64", node.methods.find { |m| m.name == "baz" }
      end

      def test_verifies_struct_variable_accessors
        ex = assert_raises(SemanticError) { visit "struct Foo; @bar : i32; def initialize; @bar; end; end" }
        assert_match "accessing uninitialized instance variable '@bar'", ex.message

        ex = assert_raises(SemanticError) { visit "struct Foo; def bar; @unknown; end; end" }
        assert_match "undefined instance variable '@unknown'", ex.message

        ex = assert_raises(SemanticError) { visit "struct Foo; def bar; @unknown = 0; end; end" }
        assert_match "undefined instance variable '@unknown'", ex.message

        ex = assert_raises(SemanticError) do
          visit(<<-RUNIC)
          struct Foo
            @bar : i32
            def initialize; @bar = 0; end
            def set(value : f64); @bar = value; end
          end
          RUNIC
        end
        assert_match "can't assign f64 to '@bar' (i32)", ex.message
      end

      def test_verifies_struct_variables_are_initialized
        # valid: no ivars to initialize
        visit("struct Foo; end")

        # invalid: no initialize method
        ex = assert_raises(SemanticError) { visit("struct Foo; @bar : i32; @baz : f64; end") }
        assert_match "struct Foo has no 'initialize' method but instance variables must be initialized", ex.message

        # invalid: some ivars aren't initialized
        ex = assert_raises(SemanticError) do
          visit <<-RUNIC
          struct Foo
            @bar : i32
            @baz : f64

            def initialize(bar : i32)
              @bar = bar
            end
          end
          RUNIC
        end
        assert_match "instance variable '@baz' of struct Foo isn't always initialized", ex.message

        # valid: ivar is initialized in all branches:
        visit <<-RUNIC
        struct Foo
          @bar : i32

          def initialize(bar : i32)
            if bar > 0
              @bar = bar
            else
              @bar = -1
            end
          end
        end
        RUNIC

        # invalid: some ivars may be uninitialized
        ex = assert_raises(SemanticError) do
          visit <<-RUNIC
          struct Foo
            @bar : i32

            def initialize(bar : i32)
              if bar > 0
                @bar = bar
              end
            end
          end
          RUNIC
        end
        assert_match "instance variable '@bar' of struct Foo isn't always initialized", ex.message
      end

      private def assert_type(name : String, node : AST::Node, file = __FILE__, line = __LINE__)
        assert_equal name, node.type?.try(&.name), file: file, line: line
      end

      private def assert_type(name : String, node : Nil, file = __FILE__, line = __LINE__)
        flunk "expected Node but got Nil", file: file, line: line
      end

      private def assert_types(names : Array(String), nodes : Array(AST::Node), file = __FILE__, line = __LINE__)
        assert_equal names, nodes.map(&.type.name), file: file, line: line
      end

      private def register(source)
        parse_each(source) do |node|
          program.register(node)
          visitors.each(&.visit(node))
          return node
        end
        raise "unreachable"
      end

      private def visit_each(source)
        index = 0
        parse_each(source) do |node|
          visitors.each(&.visit(node))
          yield node, index
          index += 1
        end
      end

      private def visitors
        @visitor ||= [
          SugarExpanderVisitor.new(program),
          TypeVisitor.new(program),
        ]
      end
    end
  end
end
