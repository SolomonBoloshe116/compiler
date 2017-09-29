CRYSTAL ?= crystal

COMMON_SOURCES = src/version.cr
LEXER_SOURCES = $(COMMON_SOURCES) src/definitions.cr src/errors.cr src/lexer.cr src/location.cr src/token.cr
PARSER_SOURCES = $(LEXER_SOURCES) src/parser.cr src/ast.cr
SEMANTIC_SOURCES = $(PARSER_SOURCES) src/semantic.cr src/semantic/*.cr
LLVM_SOURCES = src/llvm.cr src/c/llvm.cr src/c/llvm/*.cr src/c/llvm/transforms/*.cr \
			   src/ext/llvm/di_builder.cc src/ext/llvm/di_builder.cr
CODEGEN_SOURCES = $(SEMANTIC_SOURCES) src/codegen.cr src/codegen/*.cr $(LLVM_SOURCES)

C2CR = CFLAGS=`llvm-config-5.0 --cflags` lib/clang/bin/c2cr

.PHONY: dist ext clean test

all: bin/runic libexec/runic-lex libexec/runic-ast libexec/runic-compile libexec/runic-interactive

ext:
	cd src/ext && make

dist:
	mkdir -p dist
	cp VERSION dist/
	cd dist && ln -sf ../src .
	cd dist && make -f ../Makefile CRFLAGS=--release
	rm dist/src
	mkdir dist/src && cp src/intrinsics.runic dist/src/

bin/runic: src/runic.cr $(COMMON_SOURCES)
	@mkdir -p bin
	$(CRYSTAL) build -o bin/runic src/runic.cr src/version.cr $(CRFLAGS)

libexec/runic-lex: src/runic-lex.cr $(LEXER_SOURCES)
	@mkdir -p libexec
	$(CRYSTAL) build -o libexec/runic-lex src/runic-lex.cr $(CRFLAGS)

libexec/runic-ast: src/runic-ast.cr $(SEMANTIC_SOURCES)
	@mkdir -p libexec
	$(CRYSTAL) build -o libexec/runic-ast src/runic-ast.cr $(CRFLAGS)

libexec/runic-compile: ext src/runic-compile.cr $(CODEGEN_SOURCES)
	@mkdir -p libexec
	$(CRYSTAL) build -o libexec/runic-compile src/runic-compile.cr $(CRFLAGS)

libexec/runic-interactive: ext src/runic-interactive.cr $(CODEGEN_SOURCES)
	@mkdir -p libexec
	$(CRYSTAL) build -o libexec/runic-interactive src/runic-interactive.cr $(CRFLAGS)

clean:
	rm -rf bin/runic libexec/runic-lex libexec/runic-ast libexec/runic-compile \
	  libexec/runic-interactive dist src/c/llvm
	cd src/ext && make clean

src/c/llvm/*.cr:
	cd lib/clang && make
	@mkdir -p src/c/llvm/transforms
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/Analysis.h > src/c/llvm/analysis.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/Core.h > src/c/llvm/core.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/ErrorHandling.h > src/c/llvm/error_handling.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/ExecutionEngine.h > src/c/llvm/execution_engine.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/Target.h > src/c/llvm/target.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/TargetMachine.h > src/c/llvm/target_machine.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/Transforms/Scalar.h > src/c/llvm/transforms/scalar.cr
	$(C2CR) --remove-enum-prefix=LLVM --remove-enum-suffix llvm-c/Types.h > src/c/llvm/types.cr

src/c/llvm/transforms/*.cr:
	# avoid makefile error

test:
	$(CRYSTAL) run `find test -iname "*_test.cr"` -- --verbose
