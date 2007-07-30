#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/main'
require 'metasm/preprocessor'

module Metasm
# c parser
# inspired from http://www.math.grin.edu/~stone/courses/languages/C-syntax.xhtml
class CParser
	class Statement
	end

	class Block < Statement
		attr_accessor :symbol	# hash name => Type/Variable/enum value
		attr_accessor :struct	# hash name => Struct/Union/Enum
		attr_accessor :outer	# parent block
		attr_accessor :statements	# array of statements

		def initialize(outer)
			@symbol, @struct = {}, {}
			@statements = []
			@outer = outer
		end

		def struct_ancestors
			(outer ? outer.struct_ancestors : {}).merge @struct
		end

		def symbol_ancestors
			(outer ? outer.symbol_ancestors : {}).merge @symbol
		end
	end

	module Attributes
		attr_accessor :attributes

		# parses a sequence of __attribute__((anything)) into self.attributes (array of string)
		def parse_attributes(parser)
			while tok = parser.skipspaces and tok.type == :string and tok.raw == '__attribute__'
				raise tok || parser if not tok = parser.skipspaces or tok.type != :punct or tok.type != '('
				raise tok || parser if not tok = parser.skipspaces or tok.type != :punct or tok.type != '('
				nest = 0
				attrib = ''
				loop do
					raise parser if not tok = parser.skipspaces
					if tok.type == :punct and tok.raw == ')'
						if nest == 0
							raise tok || parser if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
							break
						else
							nest -= 1
						end
					elsif tok.type == :punct and tok.raw == '('
						nest += 1
					end
					attrib << tok.raw
				end
				(@attributes ||= []) << attrib
			end
			parser.unreadtok tok
		end
	end

	class Type
		include Attributes
		attr_accessor :qualifier	# const volatile

		def pointer? ; false ; end

		def parse_initializer(parser, scope)
			raise parser, 'expr expected' if not ret = CExpression.parse(parser, scope, false)
			parser.check_compatible_type(parser, ret.type, self)
			ret
		end
	end
	class BaseType < Type
		attr_accessor :name		# :int :long :longlong :short :double :longdouble :float :char :void
		attr_accessor :specifier	# sign specifier only

		def initialize(name, *specs)
			@name = name
			specs.each { |s|
				case s
				when :const, :volatile: (@qualifier ||= []) << s
				when :signed, :unsigned: @specifier = s
				else raise "internal error, got #{name.inspect} #{specs.inspect}"
				end
			}
		end
	end
	class TypeDef < Type
		attr_accessor :name
		attr_accessor :type
		attr_accessor :backtrace

		def initialize(var)
			@name, @type, @backtrace = var.name, var.type, var.backtrace
		end

		def pointer? ; @type.pointer? ; end
	end
	class Function < Type
		attr_accessor :type		# return type
		attr_accessor :args		# [name, Variable]
		attr_accessor :varargs		# true/false

		def initialize(type=nil)
			@type = type
		end
	end
	class Union < Type
		attr_accessor :members		# [Variable]
		attr_accessor :bits		# name => len
		attr_accessor :name
		attr_accessor :backtrace
	end
	class Struct < Union
		attr_accessor :align

		def offsetof(parser, name)
			raise parser, 'undefined structure' if not @members
			raise parser, 'unknown structure member' if not @members.find { |m| m.name == name }
			off = 0
			@members.each { |m|
				break if m.name == name
				raise parser, 'offsetof unhandled with bit members' if @bits and @bits[m.name]	# TODO
				off += parser.sizeof(m.type)
				off = (off + @align - 1) / @align * @align
			}
			off
		end

		def parse_initializer(parser, scope)
			if tok = parser.skipspaces and tok.type == :punct and tok.raw == '{'
				# struct x toto = { 1, .4, .member = 12 };
				raise tok, 'undefined struct' if not @members
				ret = []
				if tok = parser.skipspaces and (tok.type != :punct or tok.raw != '}')
					parser.unreadtok tok
					idx = -1
					loop do
						nt = nnt = nnnt = nil
						if nt = parser.skipspaces and   nt.type == :punct  and   nt.raw == '.' and
						  nnt = parser.skipspaces and  nnt.type == :string and
						 nnnt = parser.skipspaces and nnnt.type == :punct  and nnnt.raw == '='
							raise nnt, 'invalid member' if not idx = @members.index(@members.find { |m| m.name == nnt.raw })
						else
							parser.unreadtok nnntok
							parser.unreadtok nntok
							parser.unreadtok ntok
							idx += 1
						end

						ret[idx] = members[idx].type.parse_initializer(parser, scope)	# XXX struct { int ary[]; } toto = { {1, 2} }; => don't def ary.length
						raise tok || parser, '"," or "}" expected' if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != '}' and tok.raw != ',')
						break if tok.raw == '}'
					end
				end
				ret
			else
				parser.unreadtok tok
				super
			end
		end
	end
	class Enum < Type
		# name => value
		attr_accessor :values
	end
	class Pointer < Type
		attr_accessor :type

		def initialize(type=nil)
			@type = type
		end

		def pointer? ; true ; end
	end
	class ArrayType < Pointer
		# class name to avoid conflict with ruby's ::Array
		attr_accessor :length

		def parse_initializer(parser, scope)
			if tok = parser.skipspaces and tok.type == :punct and tok.raw == '{'
				# int foo[] = { 1, 2, 3 };
				ret = []
				if tok = parser.skipspaces and (tok.type != :punct or tok.raw != '}')
					parser.unreadtok tok
					loop do
						ret << type.type.parse_initializer(parser, scope)
						raise tok || parser if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != '}' and tok.raw != ',')
						break if tok.raw == '}'
					end
				end
				type.length ||= ret.length
				raise parser, 'initializer too long' if type.length.kind_of? Integer and type.length < ret.length
				ret
			else
				parser.unreadtok tok
				super
			end
		end
	end

	class Variable
		include Attributes
		attr_accessor :type
		attr_accessor :initializer	# CExpr	/ Block (for Functions)
		attr_accessor :name
		attr_accessor :storage		# auto register static extern typedef
		attr_accessor :backtrace	# definition backtrace info (the name token)
	end

	class If < Statement
		attr_accessor :test		# expression
		attr_accessor :bthen, :belse	# statements
		def initialize(test, bthen, belse=nil)
			@test = test
			@bthen = bthen
			@belse = belse if belse
		end

		def self.parse(parser, scope)
			tok = nil
			raise tok || self, '"(" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '('
			raise tok, 'expr expected' if not expr = CExpression.parse(parser, scope)
			raise tok || self, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
			bthen = parser.parse_statement scope
			if tok = parser.skipspaces and tok.type == :string and tok.raw == 'else'
				belse = parser.parse_statement scope
			else
				parser.unreadtok tok
			end

			new expr, bthen, belse
		end
	end
	class For < Statement
		attr_accessor :init, :test, :iter	# CExpressions, init may be Block
		attr_accessor :body
		def initialize(init, test, iter, body)
			@init, @test, @iter, @body = init, test, iter, body
		end

		def self.parse(parser, scope)
			tok = nil
			raise tok || parser, '"(" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '('
			init = forscope = Block.new
			if not parse_definition(forscope)
				forscope = scope
				raise tok, 'expr expected' if not init = CExpression.parse(parser, forscope)
				raise tok || parser, '";" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ';'
			end
			raise tok, 'expr expected' if not test = CExpression.parse(parser, forscope)
			raise tok || parser, '";" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ';'
			raise tok, 'expr expected' if not iter = CExpression.parse(parser, forscope)
			raise tok || parser, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'

			new init, test, iter, parser.parse_statement(forscope)
		end
	end
	class While < Statement
		attr_accessor :test
		attr_accessor :body

		def initialize(test, body)
			@test = test
			@body = body
		end

		def self.parse(parser, scope)
			tok = nil
			raise tok || parser, '"(" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '('
			raise tok, 'expr expected' if not expr = CExpression.parse(parser, scope)
			raise tok || parser, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'

			new expr, parser.parse_statement(scope)
		end
	end
	class DoWhile < While
		def self.parse(parser, scope)
			body = parser.parse_statement scope
			tok = nil
			raise tok || parser, '"while" expected' if not tok = parser.skipspaces or tok.type != :string or tok.raw != 'while'
			raise tok || parser, '"(" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '('
			raise tok, 'expr expected' if not expr = CExpression.parse(parser, scope)
			raise tok || parser, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
			raise tok || parser, '";" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ';'

			new expr, body
		end
	end
	class Switch < Statement
		attr_accessor :test, :body

		def initialize(test, body)
			@test = test
			@body = body
		end

		def self.parse(parser, scope)
			raise tok || parser, '"(" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '('
			raise tok, 'expr expected' if not expr = CExpression.parse(parser, scope)
			raise tok || parser, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'

			new expr, parser.parse_statement(scope)
		end
	end

	class Continue < Statement
	end
	class Break < Statement
	end
	class Goto < Statement
		attr_accessor :target
		def initialize(target)
			@target = target
		end
	end
	class Return < Statement
		attr_accessor :value
		def initialize(value)
			@value = value
		end
	end
	class Label < Statement
		attr_accessor :name
		attr_accessor :statement
		def initialize(name, statement)
			@name, @statement = name, statement
		end
	end
	class Case < Label
		attr_accessor :expr, :exprup	# exprup if range
		def initialize(expr, exprup, statement)
			@expr, @statement = expr, statement
			@exprup = exprup if exprup
		end

		def self.parse(parser, scope)
			raise parser if not expr = CExpression.parse(parser, scope)
			raise tok || parser, '":" or "..." expected' if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != ':' and tok.raw != '.')
			if tok.raw == '.'
				raise tok || parser, '".." expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '.'
				raise tok || parser,  '"." expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '.'
				raise tok if not exprup = CExpression.parse(parser, scope)
				raise tok || parser, '":" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ':'
			end
			body = parser.parse_statement scope
			new expr, exprup, body
		end
	end

	# inline asm statement
	class Asm < Statement
		attr_accessor :body		# asm source (String)
		attr_accessor :output, :input, :clobber	# I/O, gcc-style (Arrays)
		attr_accessor :backtrace	# body Token
		attr_accessor :volatile

		def initialize(body, backtrace, output, input, clobber, volatile)
			@body, @backtrace, @output, @input, @clobber, @volatile = body, backtrace, output, input, clobber, volatile
		end
		
		def self.parse(parser, scope)
			if tok = parser.skipspaces and tok.type == :string and (tok.raw == 'volatile' or tok.raw == '__volatile__')
				volatile = true
				tok = parser.skipspaces
			end
			raise tok || parser, '"(" expected' if not tok or tok.type != :punct or tok.raw != '('
			raise tok || parser, 'qstring expected' if not tok = parser.skipspaces or tok.type != :quoted
			body = tok
			tok = parser.skipspaces
			raise tok || parser, '":" or ")" expected' if not tok or tok.type != :punct or (tok.raw != ':' and tok.raw != ')')

			if tok.raw == ':'
				output = []
				raise parser if not tok = parser.skipspaces
				while tok.type == :quoted
					type = tok.value
					raise tok, 'expr expected' if not var = CExpression.parse_value(parser, scope)
					output << [type, var]
					raise tok || parser, '":" or "," or ")" expected' if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != ',' and tok.raw != ')' and tok.raw != ':')
					break if tok.raw == ':' or tok.raw == ')'
					raise tok || parser, 'qstring expected' if not tok = parser.skipspaces or tok.type != :quoted
				end
			end
			if tok.raw == ':'
				input = []
				raise parser if not tok = parser.skipspaces
				while tok.type == :quoted
					type = tok.value
					raise tok, 'expr expected' if not var = CExpression.parse_value(parser, scope)
					input << [type, var]
					raise tok || parser, '":" or "," or ")" expected' if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != ',' and tok.raw != ')' and tok.raw != ':')
					break if tok.raw == ':' or tok.raw == ')'
					raise tok || parser, 'qstring expected' if not tok = parser.skipspaces or tok.type != :quoted
				end
			end
			if tok.raw == ':'
				clobber = []
				raise parser if not tok = parser.skipspaces
				while tok.type == :quoted
					clobber << tok.value
					raise tok || parser, '"," or ")" expected' if not tok = parser.skipspaces or tok.type != :punct or (tok.raw != ',' and tok.raw != ')')
					break if tok.raw == ')'
					raise tok || parser, 'qstring expected' if not tok = parser.skipspaces or tok.type != :quoted
				end
			end
			raise tok || parser, '")" expected' if not tok or tok.type != :punct or tok.raw != ')'
			raise tok || parser, '";" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ';'

			new body.value, body, output, input, clobber, volatile
		end
	end

	class CExpression < Statement
		# op may be :,, :., :->, :funcall (function, [arglist]), :[] (array indexing)
		attr_accessor :op
		# may be nil/Variable/String( = :quoted)/Integer/Float
		attr_accessor :lexpr, :rexpr
		# a Type
		attr_accessor :type
		def initialize(l, o, r, t)
			@lexpr, @op, @rexpr, @type = l, o, r, t
		end
	end

	# creates a new CParser, parses all top-level statements
	def self.parse(text, file='unknown', lineno=1)
		c = new
		c.lexer.feed text, file, lineno
		nil while not c.lexer.eos? and c.parse_definition(c.toplevel)
		raise c.lexer.readtok || c, 'EOF expected' if not c.lexer.eos?
		c.sanity_checks
		c
	end

	attr_accessor :lexer, :toplevel, :typesize
	def initialize(lexer = nil, model=:ilp32)
		@lexer = lexer || Preprocessor.new
		@lexer.feed <<EOS, 'metasm_intern_init'
#ifndef inline
# define inline __attribute__((inline))
#endif
#ifndef __declspec
# define __declspec(a) __attribute__((a))
# define __cdecl    __declspec(cdecl)
# define __stdcall  __declspec(stdcall)
# define __fastcall __declspec(fastcall)
#endif
EOS
		@lexer.readtok until @lexer.eos?
		@toplevel = Block.new(nil)
		@unreadtoks = []
		send model
	end

	def lp32
		@typesize = { :char => 1, :short => 2, :ptr => 4,
			:int => 2, :long => 4, :longlong => 8,
			:float => 4, :double => 8, :longdouble => 12 }
	end
	def ilp32
		@typesize = { :char => 1, :short => 2, :ptr => 4,
			:int => 4, :long => 4, :longlong => 8,
			:float => 4, :double => 8, :longdouble => 12 }
	end
	def llp64
		# longlong should only exist here
		@typesize = { :char => 1, :short => 2, :ptr => 8,
			:int => 4, :long => 4, :longlong => 8,
			:float => 4, :double => 8, :longdouble => 12 }
	end
	def ilp64
		@typesize = { :char => 1, :short => 2, :ptr => 8,
			:int => 8, :long => 8, :longlong => 8,
			:float => 4, :double => 8, :longdouble => 12 }
	end
	def lp64
		@typesize = { :char => 1, :short => 2, :ptr => 8,
			:int => 4, :long => 8, :longlong => 8,
			:float => 4, :double => 8, :longdouble => 12 }
	end

	# C sanity checks
	#  toplevel initializers are constants (including struct members and bit length)
	#  array lengthes are constant at toplevel
	#  no variable is of type :void
	#  all Case are in Switch, Goto target exists, Continue/Break are placed correctly
	#  etc..
	def sanity_checks
		return if not $VERBOSE
		#  TODO
	end

	# checks that the types are compatible (variable predeclaration, function argument..)
	# strict = false for func call/assignment (eg char compatible with int -- but int is incompatible with char)
	def check_compatible_type(tok, oldtype, newtype, strict = false)
		puts tok.exception('type qualifier mismatch').message if oldtype.qualifier != newtype.qualifier

		oldtype = oldtype.type while oldtype.kind_of? TypeDef
		newtype = newtype.type while newtype.kind_of? TypeDef
		oldtype = BaseType(:int) if oldtype.kind_of? Enum
		newtype = BaseType(:int) if newtype.kind_of? Enum

		case newtype
		when Function
			raise tok, 'incompatible type' if not oldtype.kind_of? Function
			check_compatible_type tok, oldtype.type, newtype.type, strict
			if oldtype.args and newtype.args
				if oldtype.args.length != newtype.args.length or
						oldtype.varargs != newtype.varargs
					raise tok, 'incompatible type'
				end
				oldtype.args.zip(newtype.args) { |oa, na|
					# begin ; rescue ParseError: raise $!.message + "in parameter #{oa.name}" end
					check_compatible_type tok, oa.type, na.type, strict
				}
			end
		when Pointer
			raise tok, 'incompatible type' if not oldtype.kind_of? Pointer
			# allow any pointer to void*
			check_compatible_type tok, oldtype.type, newtype.type, strict if strict or newtype.type != :void
		when Union
			raise tok, 'incompatible type' if not oldtype.class == newtype.class
			if oldtype.members and newtype.members
				if oldtype.members.length != newtype.members.length
					raise tok, 'incompatible type'
				end
				oldtype.members.zip(newtype.members) { |om, nm|
					# don't care
					#if om.name and nm.name and om.name != nm.name
					#	raise tok, 'incompatible type'
					#end
					check_compatible_type tok, om.type, nm.type, strict
				}
			end
		when BaseType
			if strict
				if oldtype.name != newtype.name or
				oldtype.qualifier != newtype.qualifier or
				oldtype.specifier != newtype.specifier
					raise tok, 'incompatible type'
				end
			else
				# void type not allowed
				raise tok, 'incompatible type' if oldtype.name == :void or newtype.name == :void
				# check int/float mix	# TODO float -> int allowed ?
				raise tok, 'incompatible type' if oldtype.name != newtype.name and ([:char, :int, :short, :long, :longlong] & [oldtype.name, newtype.name]).length == 1
				# check int size/sign
				raise tok, 'incompatible type' if @typesize[oldtype.name] > @typesize[newtype.name]
				puts tok.exception('sign mismatch').message if $VERBOSE and oldtype.specifier != newtype.specifier and @typesize[newtype.name] == @typesize[oldtype.name]
			end
		end
	end

	Reserved = %w[struct union enum  if else for while do switch goto
			register extern auto static typedef  const volatile
			void int float double char  signed unsigned long short
			case continue break return  __attribute__ asm __asm__
	].inject({}) { |h, w| h.update w => true }

	# allows 'raise self'
	def exception(msg='EOF unexpected')
		raise @lexer, msg
	end

	# reads a token, convert 'L"foo"' to a :quoted
	def readtok_longstr
		if t = @lexer.readtok and t.type == :string and t.raw == 'L' and
		nt = @lexer.readtok and nt.type == :quoted and nt.raw[0] == ?"
			nt.raw[0, 0] = 'L'
			nt
		else
			@lexer.unreadtok nt
			t
		end
	end
	private :readtok_longstr

	# reads a token from self.lexer
	# concatenates strings, merges spaces/eol to ' ', handles wchar strings
	def readtok
		if not t = @unreadtoks.pop
			t = readtok_longstr
			case t.type
			when :space, :eol
				# merge consecutive :space/:eol
				t = t.dup
				t.type = :space
				t.raw = ' '
				nil while nt = @lexer.readtok and (nt.type == :eol or nt.type == :space)
				@lexer.unreadtok nt

			when :quoted
				# merge consecutive :quoted
				t = t.dup
				while nt = readtok_longstr and nt.type == :quoted
					if t.raw[0] == ?" and nt.raw[0, 1] == 'L"'
						# ensure wide prefix is set
						t.raw[0, 0] = 'L'
					end
					t.raw << ' ' << nt.raw
					t.value << nt.value
				end
				@lexer.unreadtok nt
			end
		end
		t
	end

	def unreadtok(tok)
		@unreadtoks << tok if tok
	end

	# returns the next non-space/non-eol token
	def skipspaces
		nil while t = readtok and t.type == :space
		t
	end

	# returns the size of a type in bytes
	def sizeof(type)
		# XXX double-check class apparition order ('when' checks inheritance)
		case type
		when ArrayType
			raise self, 'unknown array size' if not type.length or not type.length.kind_of? Integer
			type.length * sizeof(type.type)
		when Pointer
			@typesize[:ptr]
		when Function
			# raise # gcc responds 1
			1
		when BaseType
			@typesize[type.name]
		when Enum
			@typesize[:int]
		when Struct
			raise self, 'unknown structure size' if not type.members
			type.members.map { |m| (sizeof(m.type) + type.align - 1) / type.align * type.align }.inject(0) { |a, b| a+b }
		when Union
			raise self, 'unknown structure size' if not type.members
			type.members.map { |m| sizeof(m.type) }.max || 0
		when TypeDef
			sizeof(type.type)
		end
	end

	# parses variable/function definition/declaration/initialization
	# populates scope.symbols and scope.struct
	# raises on redefinitions
	# returns false if no definition found
	def parse_definition(scope)
		return false if not basetype = Variable.parse_type(self, scope, true)

		# check struct predeclaration
		tok = skipspaces
		if tok and tok.type == :punct and tok.raw == ';' and basetype.type and
				(basetype.type.kind_of? Union or basetype.type.kind_of? Enum)
			return true
		else unreadtok tok
		end

		nofunc = false
		loop do
			var = basetype.dup
			var.parse_declarator(self, scope)

			raise self if not var.name	# barrel roll

			if prev = scope.symbol[var.name] and (
					not scope.symbol[var.name].kind_of?(Variable) or
					scope.symbol[var.name].initializer)
				raise var.backtrace, 'redefinition'
			elsif var.storage == :typedef
				var = TypeDef.new var
			elsif prev
				check_compatible_type prev.backtrace, prev.type, var.type, true
				# XXX forward attributes ?
			end
			scope.symbol[var.name] = var

			raise tok || self, 'punctuation expected' if not tok = skipspaces or tok.type != :punct

			case tok.raw
			when '{'
				# function body
				raise tok if nofunc or not var.kind_of? Variable or not var.type.kind_of? Function
				body = var.initializer = Block.new(scope)
				var.type.args.each { |v|
					# put func parameters in func body scope
					# arg redefinition is checked in parse_declarator
					if not v.name
						puts "unnamed argument in definition" if $VERBOSE
						next	# should raise
					end
					body.variable[v.name] = v	# XXX will need special check in stack allocator
				}

				loop do
					raise tok || self, '"}" expected' if not tok = skipspaces
					break if tok.type == :punct and tok.raw == '}'
					unreadtok tok
					if not parse_definition(body)
						body.statements << parse_statement(body)
					end
				end
				break
			when '='
				# variable initialization
				raise tok, '"{" or ";" expected' if var.type.kind_of? Function
				raise tok, 'cannot initialize extern variable' if var.storage == :extern
				var.initializer = var.type.parse_initializer(self, scope)
				raise tok || self, '"," or ";" expected' if not tok = skipspaces or tok.type != :punct
			end

			case tok.raw
			when ',': nofunc = true
			when ';': break
			else raise tok, '";" or "," expected'
			end
		end
		true
	end

	# returns a statement or raise
	def parse_statement(scope)
		raise self, 'statement expected' if not tok = skipspaces

		if tok.type == :punct and tok.raw == '{'
			body = Block.new scope
			loop do
				raise tok || self, '"}" expected' if not tok = skipspaces
				break if tok.type == :punct and tok.raw == '}'
				unskipspaces tok
				if not parse_definition(body)
					body.statements << parse_statement(body)
				end
			end
			return body
		elsif tok.type != :string
			unskipspaces tok
			raise tok, 'expr expected' if not expr = CExpression.parse(self, scope)
			raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'

			if $VERBOSE and (expr.op or not expr.type.kind_of? BaseType or expr.type.name != :void) and expr.is_constant
				puts tok.exception('statement with no effect')
			end
			return expr
		end

		case tok.raw
		when 'if'
			If.parse self, scope
		when 'switch'
			Switch.parse self, scope
		when 'case'
			Case.parse self, scope
		when 'while'
			While.parse self, scope
		when 'do'
			DoWhile.parse self, scope
		when 'for'
			For.parse self, scope
		when 'goto'
			raise tok || self, 'label expected' if not tok = skipspaces or tok.type != :string
			name = tok.raw
			raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'
			Goto.new name
		when 'return'
			expr = CExpression.parse(self, scope)	# nil allowed
			raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'
			Return.new expr
		when 'continue'
			raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'
			Continue.new
		when 'break'
			raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'
			Break.new
		when 'asm', '__asm__'
			Asm.parse self, scope
		else
			if ntok = skipspaces and ntok.type == :punct and ntok.raw == ':'
				Label.new tok.raw, parse_statement(scope)
			else
				unreadtok ntok
				unreadtok tok
				raise tok, 'expr expected' if not expr = CExpression.parse(self, scope)
				raise tok || self, '";" expected' if not tok = skipspaces or tok.type != :punct or tok.raw != ';'

				if $VERBOSE and (expr.op or not expr.type.kind_of? BaseType or expr.type.name != :void) and expr.is_constant
					puts tok.exception('statement with no effect')
				end
				expr
			end
		end
	end

	class Variable
		# parses a variable basetype/qualifier/(storage if allow_value), returns a new variable of this type
		# populates scope.struct
		def self.parse_type(parser, scope, allow_value = false)
			var = new
			qualifier = []
			loop do
				break if not tok = parser.skipspaces
				if tok.type != :string
					parser.unreadtok tok
					break
				end
	
				case tok.raw
				when 'const', 'volatile'
					qualifier << tok.raw.to_sym
					next
				when 'register', 'auto', 'static', 'typedef', 'extern'
					raise tok, 'storage specifier not allowed here' if not allow_value
					raise tok, 'multiple storage class' if var.storage
					var.storage = tok.raw.to_sym
					next
				when 'struct'
					var.type = Struct.new
					var.type.align = parser.lexer.pragma_pack
					var.parse_type_unionstruct(parser, scope)
				when 'union'
					var.type = Union.new
					var.parse_type_unionstruct(parser, scope)
				when 'enum'
					var.type = Enum.new
					var.parse_type_enum(parser, scope)
				when 'long', 'short', 'signed', 'unsigned', 'int', 'char', 'float', 'double', 'void'
					parser.unreadtok tok
					var.parse_type_base(parser, scope)
				else
					if type = scope.symbol_ancestors[tok.raw] and type.kind_of? TypeDef
						var.type = type.dup
					else
						parser.unreadtok tok
					end
				end
	
				break
			end
	
			if not var.type
				raise parser, 'bad type name' if not qualifier.empty? or var.storage
				nil
			else
				(var.type.qualifier ||= []).concat qualifier if not qualifier.empty?
				var.type.parse_attributes(parser)
				var
			end
		end
	
		# parses a structure/union declaration
		def parse_type_unionstruct(parser, scope)
			if tok = parser.skipspaces and tok.type == :punct and tok.raw == '{'
				# anonymous struct, ok
				@type.backtrace = tok
			elsif tok and tok.type == :string
				name = tok.raw
				raise tok, 'bad struct name' if Reserved[name]
				@type.parse_attributes(parser)
				raise parser if not ntok = parser.skipspaces
				if ntok.type != :punct or ntok.raw != '{'
					# variable declaration
					parser.unreadtok ntok
					if ntok.type == :punct and ntok.raw == ';'
						# struct predeclaration
						# allow redefinition
						scope.struct[name] ||= var.type
					else
						# check that the structure exists
						# do not check it is declared (may be a pointer)
						struct = scope.struct_ancestors[name]
						raise tok, 'undeclared struct' if not struct
						(struct.attributes ||= []).concat @type.attributes if @type.attributes
						@type = struct
					end
					return
				end
				raise tok, 'struct redefinition' if scope.struct[name] and scope.struct[name].members
				scope.struct[name] = @type
				@type.backtrace = tok
			else
				raise tok || parser, 'struct name or "{" expected'
			end
	
			@type.members = []
			# parse struct/union members in definition
			loop do
				raise parser if not tok = parser.skipspaces
				break if tok.type == :punct and tok.raw == '}'
				parser.unreadtok tok
	
				basetype = Variable.parse_type(parser, scope)
				raise parser if not basetype.type
				loop do
					member = basetype.dup
					parse_declarator(scope, member)
					# raise parser if not member.name	# can be useful while hacking: struct foo {int; int*; int iwant;};
					raise parser, 'member redefinition' if member.name and @type.members.find { |m| m.name == member.name }
					@type.members << member
	
					raise tok || parser if not tok = parser.skipspaces or tok.type != :punct
	
					if tok.raw == ':'	# bits
						raise parser if not bits = CExpression.parse(parser, scope) or not bits = bits.reduce
						(@type.bits ||= {})[member.name] = bits if member.name
						raise parser if not tok = parser.skipspaces or tok.type != :punct
					end
	
					case tok.raw
					when ';': break
					when ','
					else raise tok, '"," or ";" expected'
					end
				end
			end
			@type.parse_attributes(parser)
	
			if @type.kind_of? Struct and @type.attributes and @type.attributes.include? 'packed'
				@type.align = 1
			end
		end
	
		def parse_type_enum(parser, scope)
			if tok = parser.skipspaces and tok.type == :punct and tok.raw == '{'
				# ok
			elsif tok and tok.type == :string
				# enum name
				name = tok.raw
				raise tok, 'bad enum name' if Reserved[name]
				@type.parse_attributes(parser)
				raise parser if not ntok = parser.skipspaces
				if ntok.type != :punct or ntok.raw != '{'
					parser.unreadtok ntok
					if ntok.type == :punct and ntok.raw == ';'
						# predeclaration
						# allow redefinition
						scope.enum[name] ||= @type
					else
						# check that the enum exists
						enum = scope.symbol_ancestors[name]
						raise tok, 'undeclared enum' if not enum or not enum.kind_of? Enum
						(enum.attributes ||= []).concat @type.attributes if @type.attributes
						@type = enum
					end
					return
				end
				raise tok, 'enum redefinition' if scope.enum[name] and scope.enum[name].values
				scope.enum[name] = @type
				@type.backtrace = tok
			else
				raise tok, 'enum name expected'
			end
	
			val = -1
			loop do
				raise parser if not tok = parser.skipspaces
				break if tok.type == :punct and tok.raw == '}'
	
				raise tok if tok.type != :string or Reserved[tok.raw]
				name = tok.raw
				raise tok, 'enum value redefinition' if scope.symbol[name]
	
				raise parser if not tok = parser.skipspaces
				if tok.type == :punct and tok.raw == '='
					raise tok || parser if not val = CExpression.parse(parser, scope) or not val = val.reduce or not tok = parser.skipspaces
				else
					val += 1
				end
				(@type.values ||= {})[name] = val
				scope.symbol[name] = val
	
				if tok.type == :punct and tok.raw == '}'
					break
				elsif tok.type == :punct and tok.raw == ','
				else raise tok
				end
			end
			@type.parse_attributes(parser)
		end

		# parses int/long int/long long/double etc
		def parse_type_base(parser, scope)
			specifier = []
			qualifier = []
			name = :int
			tok = nil
			loop do
				raise parser if not tok = parser.skipspaces
				if tok.type != :string
					parser.unreadtok tok
					break
				end
				case tok.raw
				when 'const', 'volatile'
					qualifier << tok.raw.to_sym
				when 'long', 'short', 'signed', 'unsigned'
					specifier << tok.raw.to_sym
				when 'int', 'char', 'void', 'float', 'double'
					name = tok.raw.to_sym
					break
				else
					parser.unreadtok tok
					break
				end
			end
	
			case name
			when :double	# long double
				if specifier == [:long]
					name = :longdouble
					specifier.clear
				elsif not specifier.empty?
					raise tok || parser, 'invalid specifier list'
				end
			when :int	# short, long, long long X signed, unsigned
				specifier = specifier - [:long] + [:longlong] if (specifier & [:long]).length == 2
				if (specifier & [:signed, :unsigned]).length > 1 or (specifier & [:short, :long, :longlong]).length > 1
					raise tok || parser, 'invalid specifier list'
				else
					name = (specifier & [:longlong, :long, :short])[0] || :int
					specifier -= [:longlong, :long, :short]
				end
				specifier.delete :signed	# default
			when :char	# signed, unsigned
				# signed char != char and unsigned char != char
				if (specifier & [:signed, :unsigned]).length > 1 or (specifier & [:short, :long]).length > 0
					raise tok || parser, 'invalid specifier list'
				end
			else		# none
				raise tok || parser, 'invalid specifier list' if not specifier.empty?
			end
	
			@type = BaseType.new(name, *specifier)
			@type.qualifier = qualifier if not qualifier.empty?
		end

		# updates @type and @name, parses pointer/arrays/function declarations
		# parses anonymous declarators (@name will be false)
		# the caller is responsible for detecting redefinitions
		# scope used only in CExpression.parse for array sizes and function prototype argument types
		def parse_declarator(parser, scope)
			raise parser if not tok = parser.skipspaces
			# read upto name
			if tok.type == :punct and tok.raw == '*'
				ptr = Pointer.new
				ptr.parse_attributes(parser)
				parse_declarator(parser, scope)
				t = self
				t = t.type while t.type and (t.type.kind_of?(Pointer) or t.type.kind_of?(Function))
				ptr.type = t.type
				t.type = ptr
				return
			elsif tok.type == :punct and tok.raw == '('
				parse_declarator(parser, scope)
				raise tok || parser, '")" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
			elsif tok.type == :string
				raise tok if @name or @name == false
				raise tok, 'bad var name' if Reserved[tok.raw]
				@name = tok.raw
				@backtrace = tok
				parse_attributes(parser)
			else
				# unnamed
				raise tok if @name or @name == false
				@name = false
				@backtrace = tok
				parser.unreadtok tok
				parse_attributes(parser)
			end
			parse_declarator_postfix(parser, scope)
		end
	
		# parses array/function type
		def parse_declarator_postfix(parser, scope)
			if tok = parser.skipspaces and tok.type == :punct and tok.raw == '['
				# array indexing
				t = self
				t = t.type while t.type and (t.type.kind_of?(Pointer) or t.type.kind_of?(Function))
				t.type = ArrayType.new t.type
				t.type.length = CExpression.parse(parser, scope)	# may be nil
				raise tok || parser, '"]" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ']'
				parse_attributes(parser)	# should be type.attrs, but this is should be more compiler-compatible
			elsif tok and tok.type == :punct and tok.raw == '('
				# function prototype
				t = self
				t = t.type while t.type and (t.type.kind_of?(Pointer) or t.type.kind_of?(Function))
				t.type = Function.new t.type
				if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
					parser.unreadtok tok
					t.type.args = []
					loop do
						raise parser if not tok = parser.skipspaces
						if tok.type == :punct and tok.raw == '.'	# variadic function
							raise parser, '"..." expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '.'
							raise parser, '"..." expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != '.'
							raise parser, '")" expected'   if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ')'
							t.type.varargs = true
							break
						elsif tok.type == :string and tok.raw == 'register'
							storage = :register
						else
							parser.unreadtok tok
						end
	
						raise tok if not v = Variable.parse_type(parser, scope)
						v.storage = storage if storage
						v.parse_declarator(parser, scope)
	
						args << v if not v.type.kind_of? BaseType or v.type.name != :void
						if tok = parser.skipspaces and tok.type == :punct and tok.raw == ','
							raise tok, '")" expected' if args.last != v		# last arg of type :void
						elsif tok and tok.type == :punct and tok.raw == ')'
							break
						else raise tok || parser, '"," or ")" expected'
						end
					end
				end
				parse_attributes(parser)	# should be type.attrs, but this is should be more compiler-compatible
			else
				parser.unreadtok tok
				return
			end
			parse_declarator_postfix(parser, scope)
		end
	end

	class CExpression
		def is_lvalue
			case @op
			when :*: true if not @lvalue
			when :'[]': true
			when nil	# cast
				@rvalue.kind_of?(CExpression) ?
					@rvalue.is_lvalue :
					(@rvalue.kind_of?(Variable) and @rvalue.name)
			else false
			end
		end

		def is_constant
			# gcc considers '1, 2' not constant
			case @op
			when :',', :funcall, :'--', :'++'
				false
			else
				if @op.to_s[-1] == ?= and @op != :'==' and @op != :'!='
					false
				else
					out = true
					walk { |e| break out = false if e.kind_of? CExpression and not e.is_constant }
					out
				end
			end
		end

		def reduce
		end

		def walk
			case @op
			when :funcall
				@rexpr.each { |arg| yield arg }
			when :'->', :'.'
				yield @lexpr
			when :'?:'
				yield @lexpr
				yield @rexpr[0] if @rexpr[0]
				yield @rexpr[1] if @rexpr[1]
			else
				yield @lexpr if @lexpr
				yield @rexpr if @rexpr
			end
		end

	class << self
		RIGHTASSOC = [:'=', :'+=', :'-=', :'*=', :'/=', :'%=', :'&=',
			:'|=', :'^=', :'<<=', :'>>='
		].inject({}) { |h, op| h.update op => true }

		# key = operator, value = hash regrouping operators of lower precedence
		# funcall/array index/member dereference/sizeof are handled in parse_value
		OP_PRIO = [[:','], [:'?:'], [:'=', :'+=', :'-=', :'*=', :'/=',
			:'%=', :'&=', :'|=', :'^=', :'<<=', :'>>='], [:'||'],
			[:'&&'], [:|], [:^], [:&], [:'==', :'!='],
			[:'<', :'>', :'<=', :'>='], [:<<, :>>], [:+, :-],
			[:*, :/, :%], ].inject({}) { |h, oplist|
				lessprio = h.keys.inject({}) { |hh, op| hh.update op => true }
				oplist.each { |op| lessprio.update op => true } if RIGHTASSOC[oplist.first]
				oplist.each { |op| h[op] = lessprio }
				h }

		# reads a binary operator from the parser, returns the corresponding symbol or nil
		def readop(parser)
			if not tok = parser.readtok or tok.type != :punct
				parser.unreadtok tok
				return
			end

			op = tok
			case op.raw
			# << >> || &&
			when '>', '<', '|', '&'
				if ntok = parser.readtok and ntok.type == :punct and ntok.raw == op.raw
					op.raw << parser.readtok.raw
				else
					parser.unreadtok ntok
				end
			# != (mandatory)
			when '!'
				if not ntok = parser.nexttok or ntok.type != :punct and ntok.raw != '='
					parser.unreadtok tok
					return
				end
				op.raw << parser.readtok.raw
			when '+', '-', '*', '/', '%', '^', '=', '&', '|', ',', '?', ':'
				# ok
			else
				# bad
				parser.unreadtok tok
				return
			end

			# may be followed by '='
			case tok.raw
			when '+', '-', '*', '/', '%', '^', '&', '|', '>>', '<<', '<', '>', '='
				if ntok = parser.readtok and ntok.type == :punct and ntok.raw == '='
					op.raw << ntok.raw
				else
					parser.unreadtok ntok
				end
			end

			op.value = op.raw.to_sym
			op
		end

		# parse sizeof offsetof float immediate etc into tok.value
		def parse_intfloat(parser, scope, tok)
			if tok.type == :string and not tok.value
				case tok.raw
				when 'sizeof'
					if ntok = parser.skipspaces and ntok.type == :punct and ntok.raw == '('
						# check type
						if v = Variable.parse_type(parser, scope)
							v.parse_declarator(parser, scope)
							raise tok if v.name != false
							raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != ')'
						else
							raise tok, 'expr expected' if not v = parse(parser, scope)
							raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != ')'
						end
					else
						parser.unreadtok ntok
						raise tok, 'expr expected' if not v = parse_value(parser, scope)
					end
					tok.value = parser.sizeof(v)
					return
				when '__builtin_offsetof'
					raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != '('
					raise tok if not ntok = parser.skipspaces or ntok.type != :string or ntok.raw != 'struct'
					raise tok if not ntok = parser.skipspaces or ntok.type != :string
					raise tok, 'unknown structure' if not struct = scope.struct_ancestors[ntok.raw] or not struct.kind_of? Union or not struct.members
					raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != ','
					raise tok if not ntok = parser.skipspaces or ntok.type != :string
					tok.value = struct.offsetof(parser, ntok.raw)
					raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != ')'
					return
				end
			end

			Expression.parse_num_value(parser, tok)
		end

		def parse_lvalue(parser, scope)
			v = parse_value
			raise parser, "invalid lvalue #{v.inspect}" if not v or (v.kind_of? CExpression and not v.is_lvalue)
			v
		end

		# returns the next value from parser (parenthesised expression, immediate, variable, unary operators)
		def parse_value(parser, scope)
			return if not tok = parser.skipspaces
			case tok.type
			when :string
				parse_intfloat(parser, scope, tok)
				val = tok.value || tok.raw
				if val.kind_of? String
					raise tok, 'undefined variable' if not val = scope.symbol_ancestors[val]
				end
				case val
				when Type
					raise tok, 'invalid variable'
				when Variable
					val = parse_value_postfix(parser, scope, val)
				when Float
					# parse suffix
					type = :double
					if (?0..?9).include?(tok.raw[0])
						case tok.raw.downcase[-1]
						when ?l: type = :longdouble
						when ?f: type = :float
						end
					end
					val = CExpression.new(nil, nil, val, BaseType.new(type))

				when Integer
					# parse suffix
					# XXX 010h ?
					type = :int
					specifier = []
					if (?0..?9).include?(tok.raw[0])
						suffix = tok.raw.downcase[-3, 3] || tok.raw.downcase[-2, 2] || tok.raw.downcase[-1, 1]	# short string
						specifier << :unsigned if suffix.include?('u') # XXX or tok.raw.downcase[1] == ?x
						type = :longlong if suffix.count('l') == 2
						type = :long if suffix.count('l') == 1
					end
					val = CExpression.new(nil, nil, val, BaseType.new(type, *specifier))
				end

			when :quoted
				if tok.raw[0] == ?'
					raise tok, 'invalid character constant' if tok.value.length > 1
					val = CExpression.new(nil, nil, tok.value[0], BaseType.new(:int))
				else
					val = CExpression.new(nil, nil, tok.value, Pointer.new(BaseType.new(tok.raw[0, 1] == 'L"' ? :short : :char)))
					val = parse_value_postfix(parser, scope, val)
				end

			when :punct
				case tok.raw
				when '('
					# check type casting
					if v = Variable.parse_type(parser, scope)
						v.parse_declarator(parser, scope)
						raise tok, 'bad cast' if v.name != false
						raise ntok || tok, 'no ")" found' if not ntok = parser.readtok or ntok.type != :punct or ntok.raw != ')'
						raise ntok, 'expr expected' if not val = parse_value(parser, scope)	# parses postfix too
						val = CExpression.new(nil, nil, val, v.type)
					else
						if not val = parse(parser, scope)
							parser.unreadtok tok
							return
						end
						raise ntok || tok, 'no ")" found' if not ntok = parser.readtok or ntok.type != :punct or ntok.raw != ')'
						val = parse_value_postfix(parser, scope, val)
					end
				when '.'	# float
					parse_intfloat(parser, scope, tok)
					if not tok.value
						parser.unreadtok tok
						return
					end
					type = \
					case tok.raw.downcase[-1]
					when ?l: :longdouble
					when ?f: :float
					else :double
					end
					val = CExpression.new(nil, nil, val, BaseType.new(type))

				when '+', '-', '&', '!', '~', '*', '--', '++', '&&'
					# unary prefix
					# may have been read ahead
					
					raise parser if not ntok = parser.readtok
					# check for -- ++ &&
					if ntok.type == :punct and ntok.raw == tok.raw and %w[+ - &].include?(tok.raw)
						tok.raw << ntok.raw
					else
						parser.unreadtok ntok
					end

					case tok.raw
					when '&'
						val = parse_lvalue(parser, scope)
						val = CExpression.new(nil, tok.raw.to_sym, val, Pointer.new(val.type))
					when '++', '--'
						val = parse_lvalue(parser, scope)
						val = CExpression.new(nil, tok.raw.to_sym, val, val.type)
					when '&&'
						raise tok, 'label name expected' if not val = lexer.skipspaces or val.type != :string
						raise parser, 'GCC address of label unhandled'	# TODO
					when '*'
						raise tok, 'expr expected' if not val = parse_value(parser, scope)
						raise tok, 'not a pointer' if not val.type.pointer?
						val = CExpression.new(nil, tok.raw.to_sym, val, val.type.type)
					when '~', '!', '+', '-'
						raise tok, 'expr expected' if not val = parse_value(parser, scope)
						# TODO check type is arithmetic
						val = CExpression.new(nil, tok.raw.to_sym, val, val.type)
					else raise tok, 'internal error'
					end
				else
					parser.unreadtok tok
					return
				end
			else
				parser.unreadtok tok
				return
			end
			val
		end
		
		# parse postfix forms (postincrement, array index, struct member dereference)
		def parse_value_postfix(parser, scope, val)
			tok = parser.skipspaces
			nval = \
			if tok and tok.type == :punct
				case tok.raw
				when '-', '--', '->'
					ntok = parser.skipspaces
					if tok.raw == '-' and ntok and ntok.type == :punct and (ntok.raw == '-' or ntok.raw == '>')
						tok.raw << ntok.raw
					else
						parser.unreadtok ntok
					end

					case tok.raw
					when '-'
						parser.unreadtok tok
						nil
					when '->'
						raise tok, 'not a pointer' if not val.type.pointer?
						raise tok, 'invalid member' if not tok = parser.skipspaces or tok.type != :string
						type = val.type
						type = type.type while type.kind_of? TypeDef
						type = type.type
						type = type.type while type.kind_of? TypeDef
						raise tok, 'invalid member' if not type.kind_of? Union or not type.members or not m = type.members.find { |m| m.name == tok.raw }
						CExpression.new(val, :'->', tok.raw, m.type)
					when '--'
						raise parser, "invalid lvalue #{val.inspect}" if val.kind_of? CExpression and not val.is_lvalue
						CExpression.new(val, :'--', nil, val.type)
					end
				when '+', '++'
					ntok = parser.skipspaces
					if tok.raw == '+' and ntok and ntok.type == :punct and ntok.raw == '+'
						tok.raw << ntok.raw
					else
						parser.unreadtok ntok
					end
					case tok.raw
					when '+'
						parser.unreadtok tok
						nil
					when '++'
						raise parser, "invalid lvalue #{val.inspect}" if val.kind_of? CExpression and not val.is_lvalue
						CExpression[val, tok.raw.to_sym, nil]
					end
				when '.'
					raise tok, 'invalid member' if not tok = parser.skipspaces or tok.type != :string
					type = val.type
					type = type.type while type.kind_of? TypeDef
					raise tok, 'invalid member' if not type.kind_of? Union or not type.members or not m = type.members.find { |m| m.name == tok.raw }
					CExpression.new(val, :'.', tok.raw, m.type)
				when '['
					raise tok, 'not a pointer' if not val.type.pointer?
					raise tok, 'bad index' if not idx = parse(parser, scope)
					raise tok, 'get perpendicular ! (elsewhere)' if idx.kind_of?(CExpression) and idx.op == :','
					raise tok || parser, '"]" expected' if not tok = parser.skipspaces or tok.type != :punct or tok.raw != ']'
					type = val.type
					type = type.type while type.kind_of? TypeDef
					type = type.type
					# TODO boundscheck (and become king of the universe)
					CExpression.new(val, :'[]', idx, type)
				when '('
					type = val.type
					type = type.type while type.kind_of? TypeDef
					type = type.type if type.kind_of? Pointer
					type = type.type while type.kind_of? TypeDef
					raise tok, 'not a function' if not type.kind_of? Function

					list = parse(parser, scope)
					raise tok if not ntok = parser.skipspaces or ntok.type != :punct or ntok.raw != ')'

					args = []
					if list
						# XXX func((omg, owned))
						while list.kind_of? CExpression and list.op == :','
							args << list.lexpr
							list = list.rexpr
						end
						args << list
					end

					raise tok, "bad argument count: #{args.length} for #{type.args.length}" if (type.varargs ? (args.length < type.args.length) : (args.length != type.args.length))
					type.args.zip(args) { |ta, a| parser.check_compatible_type(tok, a, ta) }
					CExpression.new(val, :funcall, args, type.type)
				end
			end

			if nval
				parse_value_postfix(parser, scope, nval)
			else
				parser.unreadtok tok
				val
			end
		end

		def parse(parser, scope, allow_coma = true)
			opstack = []
			stack = []

			popstack = proc { 
				r, l = stack.pop, stack.pop
				case op = opstack.pop
				when :'?:'
					parser.check_compatible_type(parser, l.type, r.type)
					ll = stack.pop
					stack << CExpression.new(ll, op, [l, r], r.type)
				when :','
					stack << CExpression.new(l, op, r, r.type)
				else
					parser.check_compatible_type(parser, l.type, r.type)
					stack << CExpression.new(l, op, r, r.type)
				end
			}

			return if not e = parse_value(parser, scope)

			stack << e

			while op = readop(parser)
				case op.value
				when :'?'
					# XXX asotheusaoheusnathouhaseohusneohuathhaaaaaaaaaaaaaaaaaaaaaaaoaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
					# a, b ? c, d : e, f  ==  a, (b ? (c, d) : e), f
					until opstack.empty? or opstack.last == :','
						popstack[]
					end
					tru = parse(parser, scope)
					if op = readop(parser) and op.value == :':'
						stack << tru
						opstack << :'?:'
					else
						parser.unreadtok op
						stack << tru
						opstack << :'?:'
						stack << nil
						break
					end
				when :':'
					parser.unreadtok op
					break
				else
					if op.value == ',' and not allow_coma
						parser.unreadtok op
						break
					end
					until opstack.empty? or OP_PRIO[op.value][opstack.last]
						popstack[]
					end
					raise op, 'need rhs' if not e = parse_value(parser, scope)
					stack << e
					opstack << op.value
				end
			end

			until opstack.empty?
				popstack[]
			end

			stack.first.kind_of?(CExpression) ? stack.first : CExpression.new(nil, nil, stack.first, stack.first.type)
		end
	end
	end
end
end
