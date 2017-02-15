# Specify contrasts for coding categorical data in model matrix. Contrasts types
# are a subtype of AbstractContrasts. ContrastsMatrix types hold a contrast
# matrix, levels, and term names and provide the interface for creating model
# matrix columns and coefficient names.
#
# Contrasts types themselves can be instantiated to provide containers for
# contrast settings (currently, just the base level).
#
# ModelFrame will hold a Dict{Symbol, ContrastsMatrix} that maps column
# names to contrasts.
#
# ModelMatrix will check this dict when evaluating terms, falling back to a
# default for any categorical data without a specified contrast.


"""
Interface to describe contrast coding schemes for categorical variables.

Concrete subtypes of `AbstractContrasts` describe a particular way of converting a
categorical data vector into numeric columns in a `ModelMatrix`. Each
instantiation optionally includes the levels to generate columns for and the base
level. If not specified these will be taken from the data when a `ContrastsMatrix` is
generated (during `ModelFrame` construction).

# Constructors

For `C <: AbstractContrast`:

```julia
C()                                     # levels are inferred later 
C(levels = ::Vector{Any})               # levels checked against data later
C(base = ::Any)                         # specify base level
C(levels = ::Vector{Any}, base = ::Any) # specify levels and base
```

If specified, levels will be checked against data when generating a
`ContrastsMatrix`. Any mismatch will result in an error, because missing data
levels would lead to empty columns in the model matrix, and missing contrast
levels would lead to empty or undefined rows.

You can also specify the base level of the contrasts. The actual interpretation
of this depends on the particular contrast type, but in general it can be
thought of as a "reference" level.  It defaults to the first level.

# Concrete types

* `DummyCoding` - Code each non-base level as a 0-1 indicator column.
* `EffectsCoding` - Code each non-base level as 1, and base as -1.
* `HelmertCoding` - Code each non-base level as the difference from the mean of
  the lower levels
* `ContrastsCoding` - Manually specify contrasts matrix

The last coding type, `ContrastsCoding`, provides a way to manually specify a
contrasts matrix. For a variable `x` with k levels, a contrasts matrix `M` is a
k by k-1 matrix, that maps the k levels onto k-1 model matrix columns.
Specifically, let ``X^*`` be the full-rank indicator matrix for `x`, where
``X^*_{i,j} = 1`` if `x[i]` is level `j`, and 0 otherwise. Then the model matrix
columns generated by the contrasts matrix `M` are ``X = X^* M``.

To implement your own `AbstractContrasts` type, implement a constructor, a
`contrasts_matrix` method for constructing the actual contrasts matrix that maps
from levels to `ModelMatrix` column values, and (optionally) a `termnames`
method:

```julia
type MyCoding <: AbstractContrasts
    ...
end

contrasts_matrix(C::MyCoding, baseind, n) = ...
termnames(C::MyCoding, levels, baseind) = ...
```

"""
@compat abstract type AbstractContrasts end

# Contrasts + Levels (usually from data) = ContrastsMatrix
type ContrastsMatrix{C <: AbstractContrasts, T}
    matrix::Matrix{Float64}
    termnames::Vector{T}
    levels::Vector{T}
    contrasts::C
end

"""
    ContrastsMatrix{C<:AbstractContrasts}(contrasts::C, levels::AbstractVector)

Compute contrasts matrix for given data levels.

If levels are specified in the `AbstractContrasts`, those will be used, and likewise
for the base level (which defaults to the first level).
"""
function ContrastsMatrix{C <: AbstractContrasts}(contrasts::C, levels::AbstractVector)

    # if levels are defined on contrasts, use those, validating that they line up.
    # what does that mean? either:
    #
    # 1. contrasts.levels == levels (best case)
    # 2. data levels missing from contrast: would generate empty/undefined rows. 
    #    better to filter data frame first
    # 3. contrast levels missing from data: would have empty columns, generate a
    #    rank-deficient model matrix.
    c_levels = get(contrasts.levels, levels)
    if eltype(c_levels) != eltype(levels)
        throw(ArgumentError("mismatching levels types: got $(eltype(levels)), expected " *
                            "$(eltype(c_levels)) based on contrasts levels."))
    end
    mismatched_levels = symdiff(c_levels, levels)
    if !isempty(mismatched_levels)
        throw(ArgumentError("contrasts levels not found in data or vice-versa: " *
                            "$mismatched_levels." *
                            "\n  Data levels: $levels." *
                            "\n  Contrast levels: $c_levels"))
    end

    n = length(c_levels)
    if n == 0
        throw(ArgumentError("empty set of levels found (need at least two to compute " *
                            "contrasts)."))
    elseif n == 1
        throw(ArgumentError("only one level found: $(c_levels[1]) (need at least two to " *
                            "compute contrasts)."))
    end
    
    # find index of base level. use contrasts.base, then default (1).
    baseind = isnull(contrasts.base) ?
              1 :
              findfirst(c_levels, get(contrasts.base))
    if baseind < 1
        throw(ArgumentError("base level $(get(contrasts.base)) not found in levels " *
                            "$c_levels."))
    end

    tnames = termnames(contrasts, c_levels, baseind)

    mat = contrasts_matrix(contrasts, baseind, n)

    ContrastsMatrix(mat, tnames, c_levels, contrasts)
end

# Methods for constructing ContrastsMatrix from data. These are called in
# ModelFrame constructor and setcontrasts!.
ContrastsMatrix(C::AbstractContrasts,
                v::Union{CategoricalArray, NullableCategoricalArray}) =
    ContrastsMatrix(C, levels(v))
ContrastsMatrix{C <: AbstractContrasts}(c::Type{C},
                                        col::Union{CategoricalArray, NullableCategoricalArray}) =
    throw(ArgumentError("contrast types must be instantiated (use $c() instead of $c)"))

# given an existing ContrastsMatrix, check that all of the levels present in the
# data are present in the contrasts. Note that this behavior is different from the
# ContrastsMatrix constructor, which requires that the levels be exactly the same.
# This method exists to support things like `predict` that can operate on new data
# which may contain only a subset of the original data's levels. Checking here
# (instead of in `modelmat_cols`) allows an informative error message.
function ContrastsMatrix(c::ContrastsMatrix,
                         col::Union{CategoricalArray, NullableCategoricalArray})
    if !isempty(setdiff(levels(col), c.levels))
        throw(ArgumentError("there are levels in data that are not in ContrastsMatrix: " *
                            "$(setdiff(levels(col), c.levels))" *
                            "\n  Data levels: $(levels(col))" *
                            "\n  Contrast levels: $(c.levels)"))
    end
    return c
end

function termnames(C::AbstractContrasts, levels::AbstractVector, baseind::Integer)
    not_base = [1:(baseind-1); (baseind+1):length(levels)]
    levels[not_base]
end

nullify(x::Nullable) = x
nullify(x) = Nullable(x)

# Making a contrast type T only requires that there be a method for
# contrasts_matrix(T, v::Union{CategoricalArray, NullableCategoricalArray}).
# The rest is boilerplate.
for contrastType in [:DummyCoding, :EffectsCoding, :HelmertCoding]
    @eval begin
        type $contrastType <: AbstractContrasts
            base::Nullable{Any}
            levels::Nullable{Vector}
        end
        ## constructor with optional keyword arguments, defaulting to Nullables
        $contrastType(;
                      base=Nullable{Any}(),
                      levels=Nullable{Vector}()) = 
                          $contrastType(nullify(base),
                                        nullify(levels))
    end
end

"""
    FullDummyCoding()

Coding that generates one indicator (1 or 0) column for each level,
__including__ the base level.

Needed internally when a term is non-redundant with lower-order terms (e.g., in
`~0+x` vs. `~1+x`, or in the interactions terms in `~1+x+x&y` vs. `~1+x+y+x&y`. In the
non-redundant cases, we can expand x into `length(levels(x))` columns
without creating a non-identifiable model matrix (unless the user has done
something foolish in specifying the model, which we can't do much about anyway).
"""
type FullDummyCoding <: AbstractContrasts
# Dummy contrasts have no base level (since all levels produce a column)
end

ContrastsMatrix{T}(C::FullDummyCoding, lvls::Vector{T}) =
    ContrastsMatrix(eye(Float64, length(lvls)), lvls, lvls, C)

"Promote contrasts matrix to full rank version"
Base.convert(::Type{ContrastsMatrix{FullDummyCoding}}, C::ContrastsMatrix) =
    ContrastsMatrix(FullDummyCoding(), C.levels)

"""
    DummyCoding([base[, levels]])

Contrast coding that generates one indicator column (1 or 0) for each non-base level.

Columns have non-zero mean and are collinear with an intercept column (and
lower-order columns for interactions) but are orthogonal to each other. In a
regression model, dummy coding leads to an intercept that is the mean of the
dependent variable for base level.

Also known as "treatment coding" (`contr.treatment` in R) or "one-hot encoding".
"""
DummyCoding

contrasts_matrix(C::DummyCoding, baseind, n) = eye(n)[:, [1:(baseind-1); (baseind+1):n]]


"""
    EffectsCoding([base[, levels]])

Contrast coding that generates columns that code each non-base level as the
deviation from the base level.  For each non-base level `x` of `variable`, a
column is generated with 1 where `variable .== x` and -1 where `col .== base`.

`EffectsCoding` is like `DummyCoding`, but using -1 for the base level instead
of 0.

When all levels are equally frequent, effects coding generates model matrix
columns that are mean centered (have mean 0).  For more than two levels the
generated columns are not orthogonal.  In a regression model with an
effects-coded variable, the intercept corresponds to the grand mean.

Also known as "sum coding" (`contr.sum` in R) or "simple coding" (SPSS). Note
though that the default in R and SPSS is to use the _last_ level as the base.
Here we use the _first_ level as the base, for consistency with other coding
schemes.
"""
EffectsCoding

function contrasts_matrix(C::EffectsCoding, baseind, n)
    not_base = [1:(baseind-1); (baseind+1):n]
    mat = eye(n)[:, not_base]
    mat[baseind, :] = -1
    return mat
end

"""
    HelmertCoding([base[, levels]])

Contrasts that code each level as the difference from the average of the lower
levels.

For each non-base level, Helmert coding generates a columns with -1 for each of
n levels below, n for that level, and 0 above.

# Examples

```julia
julia> ContrastsMatrix(HelmertCoding(), collect(1:4)).matrix
4x3 Array{Float64,2}:
 -1.0  -1.0  -1.0
  1.0  -1.0  -1.0
  0.0   2.0  -1.0
  0.0   0.0   3.0
```

When all levels are equally frequent, Helmert coding generates columns that are
mean-centered (mean 0) and orthogonal.
"""
HelmertCoding

function contrasts_matrix(C::HelmertCoding, baseind, n)
    mat = zeros(n, n-1)
    for i in 1:n-1
        mat[1:i, i] = -1
        mat[i+1, i] = i
    end

    # re-shuffle the rows such that base is the all -1.0 row (currently first)
    mat = mat[[baseind; 1:(baseind-1); (baseind+1):end], :]
    return mat
end
    
"""
    ContrastsCoding(mat::Matrix[, base[, levels]])

Coding by manual specification of contrasts matrix. For k levels, the contrasts
must be a k by k-1 Matrix.
"""
type ContrastsCoding <: AbstractContrasts
    mat::Matrix
    base::Nullable{Any}
    levels::Nullable{Vector}

    function ContrastsCoding(mat, base, levels)
        if !isnull(levels)
            check_contrasts_size(mat, length(get(levels)))
        end
        new(mat, base, levels)
    end
end

check_contrasts_size(mat::Matrix, n_lev) =
    size(mat) == (n_lev, n_lev-1) ||
    throw(ArgumentError("contrasts matrix wrong size for $n_lev levels. " *
                        "Expected $((n_lev, n_lev-1)), got $(size(mat))"))

## constructor with optional keyword arguments, defaulting to Nullables
ContrastsCoding(mat::Matrix; base=Nullable{Any}(), levels=Nullable{Vector}()) = 
    ContrastsCoding(mat, nullify(base), nullify(levels))

function contrasts_matrix(C::ContrastsCoding, baseind, n)
    check_contrasts_size(C.mat, n)
    C.mat
end
