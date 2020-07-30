""" Syntax systems for generalized algebraic theories (GATs).

In general, a single theory may have many different syntaxes. The purpose of
this module to enable the simple but flexible construction of syntax systems.
"""
module Syntax
export @syntax, GATExpr, SyntaxDomainError, head, args, first, last,
  gat_typeof, gat_type_args, invoke_term, functor,
  to_json_sexpr, parse_json_sexpr, show_sexpr, show_unicode, show_latex

import Base: first, last
import Base.Meta: ParseError, show_sexpr
using Compat
using Match

using ..GAT: Context, Theory, TypeConstructor, TermConstructor
import ..GAT
import ..GAT: invoke_term
using ..Meta

# Data types
############

""" Base type for expression in the syntax of a GAT.

We define Julia types for each *type constructor* in the theory, e.g., object,
morphism, and 2-morphism in the theory of 2-categories. Of course, Julia's
type system does not support dependent types, so the type parameters are
incorporated in the Julia types. (They are stored as extra data in the
expression instances.)

The concrete types are structurally similar to the core type `Expr` in Julia.
However, the *term constructor* is represented as a type parameter, rather than
as a `head` field. This makes dispatch using Julia's type system more
convenient.
"""
abstract type GATExpr{T} end

head(::GATExpr{T}) where T = T
args(expr::GATExpr) = expr.args
first(expr::GATExpr) = first(args(expr))
last(expr::GATExpr) = last(args(expr))
gat_typeof(expr::GATExpr) = nameof(typeof(expr))
gat_type_args(expr::GATExpr) = expr.type_args

""" Get name of GAT generator expression as a `Symbol`.

If the generator has no name, returns `nothing`.
"""
function Base.nameof(expr::GATExpr{:generator})
  name = first(expr)
  isnothing(name) ? nothing : Symbol(name)
end

function Base.:(==)(e1::GATExpr{T}, e2::GATExpr{S}) where {T,S}
  T == S && e1.args == e2.args && e1.type_args == e2.type_args
end
function Base.hash(e::GATExpr, h::UInt)
  hash(args(e), hash(head(e), h))
end

function Base.show(io::IO, expr::GATExpr)
  print(io, head(expr))
  print(io, "(")
  join(io, args(expr), ",")
  print(io, ")")
end
function Base.show(io::IO, expr::GATExpr{:generator})
  value = first(expr)
  if isnothing(value)
    show(io, value) # Value `nothing` cannot be printed
  else
    print(io, value)
  end
end

struct SyntaxDomainError <: Exception
  constructor::Symbol
  args::Vector
end

function Base.showerror(io::IO, exc::SyntaxDomainError)
  print(io, "Domain error in term constructor $(exc.constructor)(")
  join(io, exc.args, ",")
  print(io, ")")
end

# Syntax
########

""" Define a *syntax* system for a generalized algebraic theory (GAT).

A syntax system consists of Julia types (with top type `GATExpr`) for each type
constructor in the signature, plus Julia functions for

1. *Generators*: creating new generator terms, e.g., objects or morphisms
2. *Accessors*: accessing type parameters, e.g., domains and codomains
3. *Term constructors*: applying term constructors, e.g., composition and
   monoidal products

Julia code for all this is generated by the macro. Any of the methods can be
overriden with custom simplification logic.
"""
macro syntax(syntax_head, mod_name, body=nothing)
  if isnothing(body); body = Expr(:block) end
  @assert body.head == :block
  syntax_name, base_types = @match syntax_head begin
    Expr(:call, [name::Symbol, args...]) => (name, args)
    name::Symbol => (name, [])
    _ => throw(ParseError("Ill-formed syntax signature $syntax_head"))
  end
  functions = map(parse_function, strip_lines(body).args)

  expr = Expr(:call, :syntax_code, Expr(:quote, syntax_name),
              esc(Expr(:ref, :Type, base_types...)),
              esc(mod_name), esc(nameof(__module__)), functions)
  Expr(:block,
    Expr(:call, esc(:eval), expr),
    :(Core.@__doc__ $(esc(syntax_name))))
end
function syntax_code(name::Symbol, base_types::Vector{Type},
                     theory_type::Type, outer_module::Module,
                     functions::Vector)
  theory = GAT.theory(theory_type)
  theory_ref = GlobalRef(parentmodule(theory_type), nameof(theory_type))

  # Generate module with syntax types and type/term generators.
  mod = Expr(:module, true, name,
    Expr(:block, [
      # Prevents error about export not being at toplevel.
      # https://github.com/JuliaLang/julia/issues/28991
      LineNumberNode(0);
      Expr(:export, [cons.name for cons in theory.types]...);
      Expr(:using, Expr(:., :., :., nameof(outer_module)));
      :(theory() = $theory_ref);
      gen_types(theory, base_types);
      gen_type_accessors(theory);
      gen_term_generators(theory, outer_module);
      gen_term_constructors(theory, outer_module);
    ]...))

  # Generate toplevel functions.
  toplevel = []
  bindings = Dict{Symbol,Any}(
    c.name => Expr(:(.), name, QuoteNode(c.name)) for c in theory.types)
  syntax_fns = Dict(parse_function_sig(f) => f for f in functions)
  for f in interface(theory)
    sig = parse_function_sig(f)
    bindings[:new] = Expr(:(.), name, QuoteNode(sig.name))
    if haskey(syntax_fns, sig)
      # Case 1: The method is overriden in the syntax body.
      expr = generate_function(replace_symbols(bindings, syntax_fns[sig]))
    elseif !isnothing(f.impl)
      # Case 2: The method has a default implementation in the theory.
      expr = generate_function(replace_symbols(bindings, f))
    else
      # Case 3: Call the default syntax method.
      params = [ gensym("x$i") for i in eachindex(sig.types) ]
      call_expr = Expr(:call, sig.name,
        [ Expr(:(::), pair...) for pair in zip(params, sig.types) ]...)
      body = Expr(:call, :new, params...)
      f_impl = JuliaFunction(call_expr, f.return_type, body)
      expr = generate_function(replace_symbols(bindings, f_impl))
    end
    push!(toplevel, expr)
  end
  Expr(:toplevel, mod, toplevel...)
end

""" Complete set of Julia functions for a syntax system.
"""
function interface(theory::Theory)::Vector{JuliaFunction}
  [ GAT.interface(theory);
    [ GAT.constructor(constructor_for_generator(cons), theory)
      for cons in theory.types ]; ]
end

""" Generate syntax type definitions.
"""
function gen_type(cons::TypeConstructor, base_type::Type=Any)::Expr
  base_expr = GlobalRef(Syntax, :GATExpr)
  base_name = if base_type == Any
    base_expr
  else
    GlobalRef(parentmodule(base_type), nameof(base_type))
  end
  expr = :(struct $(cons.name){T} <: $base_name{T}
    args::Vector
    type_args::Vector{$base_expr}
  end)
  generate_docstring(strip_lines(expr, recurse=true), cons.doc)
end
function gen_types(theory::Theory, base_types::Vector{Type})::Vector{Expr}
  if isempty(base_types)
    map(gen_type, theory.types)
  else
    map(gen_type, theory.types, base_types)
  end
end

""" Generate accessor methods for type parameters.
"""
function gen_type_accessors(cons::TypeConstructor)::Vector{Expr}
  fns = []
  sym = gensym(:x)
  for (i, param) in enumerate(cons.params)
    call_expr = Expr(:call, param, Expr(:(::), sym, cons.name))
    return_type = GAT.strip_type(cons.context[param])
    body = Expr(:ref, Expr(:(.), sym, QuoteNode(:type_args)), i)
    push!(fns, generate_function(JuliaFunction(call_expr, return_type, body)))
  end
  fns
end
function gen_type_accessors(theory::Theory)::Vector{Expr}
  vcat(map(gen_type_accessors, theory.types)...)
end

""" Generate methods for syntax term constructors.
"""
function gen_term_constructor(cons::TermConstructor, theory::Theory,
                              mod::Module; dispatch_type::Symbol=Symbol())::Expr
  head = GAT.constructor(cons, theory)
  call_expr, return_type = head.call_expr, head.return_type
  if dispatch_type == Symbol()
    dispatch_type = cons.name
  end
  body = Expr(:block)

  # Create expression to check constructor domain.
  eqs = GAT.equations(cons, theory)
  if !isempty(eqs)
    clauses = [ Expr(:call,:(==),lhs,rhs) for (lhs,rhs) in eqs ]
    conj = foldr((x,y) -> Expr(:(&&),x,y), clauses)
    insert!(call_expr.args, 2,
      Expr(:parameters, Expr(:kw, :strict, false)))
    push!(body.args,
      Expr(:if,
        Expr(:(&&), :strict, Expr(:call, :(!), conj)),
        Expr(:call, :throw,
          Expr(:call, GlobalRef(Syntax, :SyntaxDomainError),
            Expr(:quote, cons.name),
            Expr(:vect, cons.params...)))))
  end

  # Create call to expression constructor.
  type_params = gen_term_constructor_params(cons, theory, mod)
  push!(body.args,
    Expr(:call,
      Expr(:curly, return_type, Expr(:quote, dispatch_type)),
      Expr(:vect, cons.params...),
      Expr(:vect, type_params...)))

  generate_function(JuliaFunction(call_expr, return_type, body))
end
function gen_term_constructors(theory::Theory, mod::Module)::Vector{Expr}
  [ gen_term_constructor(cons, theory, mod) for cons in theory.terms ]
end

""" Generate expressions for type parameters of term constructor.

Besides expanding the implicit variables, we must handle two annoying issues:

1. Add types for method dispatch where necessary (see `GAT.add_type_dispatch`)
   FIXME: We are currently only handling the nullary case (e.g., `munit()`).
   To handle the general case, we need to do basic type inference.

2. Rebind the term constructors to ensure that user overrides are preferred over
   the default term constructors.
"""
function gen_term_constructor_params(cons, theory, mod)::Vector
  expr = GAT.expand_term_type(cons, theory)
  raw_params = @match expr begin
    Expr(:call, [name::Symbol, args...]) => args
    _::Symbol => []
  end

  bindings = Dict(c.name => GlobalRef(mod, c.name) for c in theory.terms)
  params = []
  for expr in raw_params
    expr = replace_nullary_constructors(expr, theory)
    expr = replace_symbols(bindings, expr)
    push!(params, expr)
  end
  params
end
function replace_nullary_constructors(expr, theory)
  @match expr begin
    Expr(:call, [name::Symbol]) => begin
      terms = theory.terms[findall(cons -> cons.name == name, theory.terms)]
      @assert length(terms) == 1
      Expr(:call, name, terms[1].typ)
    end
    Expr(:call, [name::Symbol, args...]) =>
      Expr(:call, name, [replace_nullary_constructors(a,theory) for a in args]...)
    _ => expr
  end
end

""" Generate methods for term generators.

Generators are extra term constructors created automatically for the syntax.
"""
function gen_term_generator(cons::TypeConstructor, theory::Theory, mod::Module)::Expr
  gen_term_constructor(constructor_for_generator(cons), theory, mod;
                       dispatch_type = :generator)
end
function gen_term_generators(theory::Theory, mod::Module)::Vector{Expr}
  [ gen_term_generator(cons, theory, mod) for cons in theory.types ]
end
function constructor_for_generator(cons::TypeConstructor)::TermConstructor
  value_param = :__value__
  params = [ value_param; cons.params ]
  typ = Expr(:call, cons.name, cons.params...)
  context = merge(Context(value_param => :Any), cons.context)
  TermConstructor(cons.name, params, typ, context)
end

# Reflection
############

""" Invoke a term constructor by name in a syntax system.

This method provides reflection for syntax systems. In everyday use the generic
method for the constructor should be called directly, not through this function.
"""
function invoke_term(syntax_module::Module, constructor_name::Symbol, args...)
  theory_type = syntax_module.theory()
  theory = GAT.theory(theory_type)
  syntax_types = Tuple(getfield(syntax_module, cons.name) for cons in theory.types)
  invoke_term(theory_type, syntax_types, constructor_name, args...)
end

""" Name of constructor that created expression.
"""
constructor_name(expr::GATExpr) = head(expr)
constructor_name(expr::GATExpr{:generator}) = gat_typeof(expr)

""" Create generator of the same type as the given expression.
"""
function generator_like(expr::GATExpr, value)::GATExpr
  invoke_term(syntax_module(expr), gat_typeof(expr),
              value, gat_type_args(expr)...)
end

""" Get syntax module of given expression.
"""
syntax_module(expr::GATExpr) = parentmodule(typeof(expr))

# Functors
##########

""" Functor from GAT expression to GAT instance.

Strictly speaking, we should call these "structure-preserving functors" or,
better, "model homomorphisms of GATs". But this is a category theory library,
so we'll go with the simpler "functor".

A functor is completely determined by its action on the generators. There are
several ways to specify this mapping:

  1. Specify a Julia instance type for each GAT type, using the required `types`
     tuple. For this to work, the generator constructors must be defined for the
     instance types.

  2. Explicitly map each generator term to an instance value, using the
     `generators` dictionary.

  3. For each GAT type (e.g., object and morphism), specify a function mapping
     generator terms of that type to an instance value, using the `terms`
     dictionary.

The `terms` dictionary can also be used for special handling of non-generator
expressions. One use case for this capability is defining forgetful functors,
which map non-generators to generators.
"""
function functor(types::Tuple, expr::GATExpr;
                 generators::AbstractDict=Dict(), terms::AbstractDict=Dict())
  # Special case: look up a specific generator.
  if head(expr) == :generator && haskey(generators, expr)
    return generators[expr]
  end

  # Special case: look up by type of term (usually a generator).
  name = constructor_name(expr)
  if haskey(terms, name)
    return terms[name](expr)
  end

  # Otherwise, we need to call a term constructor (possibly for a generator).
  # Recursively evalute the arguments.
  term_args = []
  for arg in args(expr)
    if isa(arg, GATExpr)
      arg = functor(types, arg; generators=generators, terms=terms)
    end
    push!(term_args, arg)
  end

  # Invoke the constructor in the codomain category!
  theory_type = syntax_module(expr).theory()
  invoke_term(theory_type, types, name, term_args...)
end

# Serialization
###############

""" Serialize expression as JSON-able S-expression.

The format is an S-expression encoded as JSON, e.g., "compose(f,g)" is
represented as ["compose", f, g].
"""
function to_json_sexpr(expr::GATExpr; by_reference::Function = x->false)
  if head(expr) == :generator && by_reference(first(expr))
    to_json_sexpr(first(expr))
  else
    [ string(constructor_name(expr));
      [ to_json_sexpr(arg; by_reference=by_reference) for arg in args(expr) ] ]
  end
end
to_json_sexpr(x::Union{Bool,Real,String,Nothing}; kw...) = x
to_json_sexpr(x; kw...) = string(x)

""" Deserialize expression from JSON-able S-expression.

If `symbols` is true (the default), strings are converted to symbols.
"""
function parse_json_sexpr(syntax_module::Module, sexpr;
    parse_head::Function = identity,
    parse_reference::Function = x->error("Loading terms by name is disabled"),
    parse_value::Function = identity,
    symbols::Bool = true,
  )
  theory_type = syntax_module.theory()
  theory = GAT.theory(theory_type)
  type_lens = Dict(cons.name => length(cons.params) for cons in theory.types)

  function parse_impl(sexpr::Vector, ::Val{:expr})
    name = Symbol(parse_head(symbols ? Symbol(sexpr[1]) : sexpr[1]))
    nargs = length(sexpr) - 1
    args = map(enumerate(sexpr[2:end])) do (i, arg)
      arg_kind = ((i == 1 && get(type_lens, name, nothing) == nargs-1) ||
                  arg isa Union{Bool,Number,Nothing}) ? :value : :expr
      parse_impl(arg, Val(arg_kind))
    end
    invoke_term(syntax_module, name, args...)
  end
  parse_impl(x, ::Val{:value}) = parse_value(x)
  parse_impl(x::String, ::Val{:expr}) = parse_reference(symbols ? Symbol(x) : x)
  parse_impl(x::String, ::Val{:value}) = parse_value(symbols ? Symbol(x) : x)

  parse_impl(sexpr, Val(:expr))
end

# Pretty-print
##############

""" Show the syntax expression as an S-expression.

Cf. the standard library function `Meta.show_sexpr`.
"""
show_sexpr(expr::GATExpr) = show_sexpr(stdout, expr)

function show_sexpr(io::IO, expr::GATExpr)
  if head(expr) == :generator
    print(io, repr(first(expr)))
  else
    print(io, "(")
    join(io, [string(head(expr));
              [sprint(show_sexpr, arg) for arg in args(expr)]], " ")
    print(io, ")")
  end
end

""" Show the expression in infix notation using Unicode symbols.
"""
show_unicode(expr::GATExpr) = show_unicode(stdout, expr)
show_unicode(io::IO, x::Any; kw...) = show(io, x)

function show_unicode(io::IO, expr::GATExpr; kw...)
  # By default, show in prefix notation.
  print(io, head(expr))
  print(io, "{")
  join(io, [sprint(show_unicode, arg) for arg in args(expr)], ",")
  print(io, "}")
end

function show_unicode(io::IO, expr::GATExpr{:generator}; kw...)
  print(io, first(expr))
end

function show_unicode_infix(io::IO, expr::GATExpr, op::String;
                            paren::Bool=false)
  show_unicode_paren(io, expr) = show_unicode(io, expr; paren=true)
  if (paren) print(io, "(") end
  join(io, [sprint(show_unicode_paren, arg) for arg in args(expr)], op)
  if (paren) print(io, ")") end
end

""" Show the expression in infix notation using LaTeX math.

Does *not* include `\$` or `\\[begin|end]{equation}` delimiters.
"""
show_latex(expr::GATExpr) = show_latex(stdout, expr)
show_latex(io::IO, sym::Symbol; kw...) = print(io, sym)
show_latex(io::IO, x::Any; kw...) = show(io, x)

function show_latex(io::IO, expr::GATExpr; kw...)
  # By default, show in prefix notation.
  print(io, "\\mathop{\\mathrm{$(head(expr))}}")
  print(io, "\\left[")
  join(io, [sprint(show_latex, arg) for arg in args(expr)], ",")
  print(io, "\\right]")
end

function show_latex(io::IO, expr::GATExpr{:generator}; kw...)
  # Try to be smart about using text or math mode.
  content = string(first(expr))
  if all(isletter, content) && length(content) > 1
    print(io, "\\mathrm{$content}")
  else
    print(io, content)
  end
end

function show_latex_infix(io::IO, expr::GATExpr, op::String;
                          paren::Bool=false, kw...)
  show_latex_paren(io, expr) = show_latex(io, expr, paren=true)
  sep = op == " " ? op : " $op "
  if (paren) print(io, "\\left(") end
  join(io, [sprint(show_latex_paren, arg) for arg in args(expr)], sep)
  if (paren) print(io, "\\right)") end
end

function show_latex_postfix(io::IO, expr::GATExpr, op::String; kw...)
  @assert length(args(expr)) == 1
  print(io, "{")
  show_latex(io, first(expr), paren=true)
  print(io, "}")
  print(io, op)
end

function show_latex_script(io::IO, expr::GATExpr, head::String;
                           super::Bool=false, kw...)
  print(io, head, super ? "^" : "_", "{")
  join(io, [sprint(show_latex, arg) for arg in args(expr)], ",")
  print(io, "}")
end

end
