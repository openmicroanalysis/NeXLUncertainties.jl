using Distributions
using Random
using LinearAlgebra
using Base.Threads
using Base.Iterators



"""
    MeasurementModel

`MeasurementModel` is an abstract type representing a vector function of a vector input
with correlated uncertainties.  A `MeasurementModel` is responsible for calculating
vector function outputs and the associated Jacobian matrix both evaluated at the
input values.

To emphasize that a MeasurementModel represents a vector function that takes an
UncertainValues object representing the input values into an UncertainValues object
representing the output values, the function operator has been overloaded:

    (mm::MeasurementModel)(uvs::UncertainValues)::UncertainValues

This helps you to think of a MeasurementModel as the equivalent of a function for
UncertainValues.

Furthermore, you can compose / pipe / chain `MeasurementModel`s together to implement a
multi-step calculation using the ∘ operator.  If `mm1` and `mm2` are `MeasurementModel`s
such that the inputs for `mm2` come from `mm1` (and the original inputs) then:

    (mm2 ∘ mm1)(inputs) = mm2(mm1(inputs))

Equivalently, if `mm3` and `mm4` both take the same inputs they may be computed in
parallel using:

    (mm3 | mm4)(inputs) = cat(mm3(inputs), mm4(inputs))

You can combine `∘` and `|` together like this:

    (mm2 ∘ (mm3 | mm4) ∘ mm1)(inputs) = mm2(cat(mm3(mm1(inputs)),mm4(mm1(inputs))))

which first computes `o1=mm1(inputs)` then computes `o3=mm3(inputs+o1)` and
`o4=mm4(inputs+o1)` finally  computes `mm2(inputs+o1+o3+o4)`.

Composing `MeasurementModel`s is where the magic occurs. For a complex measurement model,
it may not be feasible/possible to calculate an analytical form of the partial derivative.
However, if the model can be broken into a series of smaller composable steps for which the
analytical partial derivative can be calculated, the steps can be combined to build the
full model.  Of course this isn't magic, it results from this property of Jacobians:

``\\mathbf{J}_{g(f(x))} |_x = \\mathbf{J}_g(y) |_{f(x)} \\mathbf{J}_{f(x)} |_x``

To use this framework on your measurement model, you must implement the function
`compute(...)` for `YourMeasurementModel`.

    compute(mm::YourMeasurementModel, inputs::LabeledValues, withJac::Boolean)::MMResult

where

    MMResult = Tuple{LabeledValues, Union{Missing,AbstractMatrix{Float64}}}

The function `compute(...)` is responsible for computing the models output values and the
Jacobian of the output values with respect to the input values.  The Jacobian is a matrix
with one row per output value and one column per input value. The contents of the r,c-th
element is the partial derivative of the r-th output value with respect to the c-th input
value.

`MMResult` represents the function output values (`LabeledValues`) and the Jacobian as
an `AbstractMatrix{Float64}`.  To optimize the `compute(...)` function when used to
simply compute the vector valued function, the Jacobian must calculated only when
`withJac=true`.  If `withJac=false` then returning 'missing' for the Jacobian is
encouraged.  This facilates efficiency when using 'compute(...)' in situations like
Monte Carlo propagation (using `mcpropagate(...)`) where it is wasteful to compute
the Jacobian but you'd otherwise like to use identical code to compute the function values.
"""
abstract type MeasurementModel end

const MMResult = Tuple{LabeledValues, Union{Missing,AbstractMatrix{Float64}}}

# Allows measurement models to be used like functions
function (mm::MeasurementModel)(inputs::UncertainValues)::UncertainValues
    return propagate(mm, inputs)
end

"""
    (∘)(mm1::MeasurementModel, mm2::MeasurementModel)

Implements composition of `MeasurementModel`s.

Examples:

    (g ∘ f)(x) == propagate(ComposedMeasurementModel([f, g], true), x)
    (g ∘ f)(x) == g(f(x))
    (h ∘ g ∘ f)(x) == propagate(ComposedMeasurementModel([f, g, h], true), x)
    (h ∘ g ∘ f)(x) == h(g(f(x)))

Note:

    (h ∘ (g ∘ f))(x) == ((h ∘ g) ∘ f)(x) == (h ∘ g ∘ f)(x)
"""
function Base.:∘(mm1::MeasurementModel, mm2::MeasurementModel)
    if mm1 isa ComposedMeasurementModel
        insert!(mm1.models,1,mm2)
        return mm1
    elseif mm2 isa CompositeMeasurementModel
        push!(mm2.models,mm1)
        return mm2
    else
        return ComposedMeasurementModel([mm2, mm1], true)
    end
end

"""
    (|)(mm1::MeasurementModel, mm2::MeasurementModel)

Implements a mechanism to combine `MeasurementModel`s that work on the same input to
produce output that is the combination of the outputs of all the measurement models.  This
is useful when a calculation forks into 2 or more distinct calculations which are later
composed as is shown in the examples.

Examples:

    j = f | g # Creates a ParallelMeasurementModel([f,g], false)
    y = j(x) # where y combines the outputs of f(x) and h(x)
    z = (f | g | h)(x) # Conceptually like combine(f(x), g(x), h(x)) into a single output
    (k ∘ (f | g | h))(x) == k(z) # Conceptually like k(f(x),g(x),h(x))
"""
function Base.:|(mm1::MeasurementModel, mm2::MeasurementModel)
    if mm1 isa ParallelMeasurementModel
        push!(mm1.models, mm2)
        return mm1
    elseif mm2 isa ParallelMeasurementModel
        push!(mm2.models, mm1)
        return mm2
    else
        return ParallelMeasurementModel([mm1, mm2], true)
    end
end

"""
    propagate(mm::MeasurementModel, uvs::UncertainValues)::UncertainValues

Propagate the input (measured values as UncertainValues) through the MeasurementModel to
produce the output values (as UncertainValues).
"""
function propagate(mm::MeasurementModel, inputs::UncertainValues)::UncertainValues
    (outvals, jac) = compute(mm, LabeledValues(labels(inputs), values(inputs)), true)
    return uvs(labels(outvals), values(outvals), jac*inputs.covariance*transpose(jac))
end

"""
    mcpropagate(mm::MeasurementModel, inputs::UncertainValues, n::Int, parallel::Bool=true, rng::AbstractRNG = Random.GLOBAL_RNG)::UncertainValues

Propagate the `inputs` through the `MeasurementModel` using a MonteCarlo algorithm in which
the inputs are assumed to be represented by a `MvNormal` distribution with covariance
from `inputs`.  Performs 'n' iterations and multi-thread if `parallel=true`.
"""
function mcpropagate(mm::MeasurementModel, inputs::UncertainValues, n::Int; parallel=false, rng::AbstractRNG = Random.GLOBAL_RNG)::UncertainValues
    function perform()
        inputs = LabeledValues(inlabels, rand(rng, mvn))
        return values(compute(mm, inputs, false)[1])
    end
    mvn = MvNormal(inputs.values, inputs.covariance)
    (outvals, _) = compute(mm, LabeledValues(labels(inputs),values(inputs)), false)
    samples, inlabels = Array{Float64}(undef, (length(outvals), n)), labels(inputs)
    if parallel && (nthreads()>1)
        @threads for i in 1:n
            samples[:, i] = perform()
        end
    else
        for i in 1:n
            samples[:, i] = perform()
        end
    end
    f = fit(MvNormal, samples)
    return uvs(labels(outvals), f.μ, f.Σ.mat)
end

"""
    compute(mm::MeasurementModel, uvs::LabeledValues)::LabeledValues

Calculate the output values for the specified set of input LabeledValues.
"""
function compute(mm::MeasurementModel, inputs::LabeledValues)::LabeledValues
    (outvals, _) = compute(mm, inputs, false)
    return outvals
end

"""
    MaintainInputs <: MeasurementModel

Carry over a subset of the inputs to the next step in a calculation.  Typically used in
consort with a `ParallelMeasurementModel` when inputs to this step will also be required
in subsequent steps.  `ComposedMeasurementModel` has a `keepinputs` option that performs
the same task.
"""
struct MaintainInputs <: MeasurementModel
    labels::Vector{Label}

    MaintainInputs(uvs::UncertainValues) = new(naturalorder(uvs))
    MaintainInputs(labels::AbstractVector{Label}) = new(labels)
end

function compute(mm::MaintainInputs, inputs::LabeledValues, withJac::Bool)::MMResult
    res = collect(map(lbl->value(inputs,lbl), mm.labels))
    jac = withJac ? I : missing
    return (LabeledValues(mm.labels, res), jac)
end

"""
    ParallelMeasurementModel <: MeasurementModel

A `ParallelMeasurementModel` is a collection of `MeasurementModel`s that can be executed
simultaneously since they share the same inputs (or a subset of the same inputs).
`ParallelMeasurementModel`s should be favored over `ComposedMeasurementModel`s since
they can be threaded and combining Jacobians is more computationally efficient.

    ParallelMeasurementModel(models::AbstractVector{MeasurementModel}, multithread=false)

While `ParallelMeasurementModel` supports multi-threading, multi-threading should be used
only when the cost of the calculation is going to exceed the overhead necessary to create
and manage the thread.  Usually this means, only use `multithread=true` on one of the
outer-most steps of a large calculation where splitting the calculation can keep the
Jacobians as small as possible until the last possible moment.
"""
struct ParallelMeasurementModel <: MeasurementModel
    models::Vector{MeasurementModel}
    multi::Bool

    ParallelMeasurementModel(models::AbstractVector{MeasurementModel}, multithread=false) =
        new(models, multithread)
end

function compute(mm::ParallelMeasurementModel, inputs::LabeledValues, withJac::Bool)::MMResult
    results = Vector{MMResult}(undef, length(mm.models))
    if mm.multi && (nthreads()>1)
        @threads for i in eachindex(mm.models)
            results[i] = compute(mm.models[i], inputs, withJac)
        end
    else
        for i in eachindex(mm.models)
            results[i] = compute(mm.models[i], inputs, withJac)
        end
    end
    outvals = reduce(merge, map(tp->getindex(tp,1), results))
    jac = withJac ? vcat( map(tp->getindex(tp,2), results)...) : missing
    return (outvals, jac)
end

"""
    ComposedMeasurementModel <: MeasurementModel

A `ComposedMeasurementModel` is used when the output from step-i will be used in a
subsequent step.  Favor `ParallelMeasurementModel` whenever a collection of
`MeasurementModel`s share the same inputs (or subsets of the same inputs) since
the `ParallelMeasurementModel`s can be run on multiple threads and the Jacobians
can be concatenated rather than multiplied. `ParallelMeasurementModel`s and
`ComposedMeasurementModel`s can be combined to produce efficient calculation models.
"""
struct ComposedMeasurementModel <: MeasurementModel
    models::Vector{MeasurementModel}
    keepinputs::Bool
end

function compute(smm::ComposedMeasurementModel, inputs::LabeledValues, withJac::Bool)::MMResult
    # N inputs
    current, currjac = copy(inputs), withJac ? I : missing
    for model in smm.models
        (outvals, jac) = compute(model, current, withJac)
        merge!(current, outvals)
        # length(current) = N + sum(Ni,1:i)
        currjac = withJac ? vcat(I, jac) * currjac : missing
        # size(currjac) = ( length(next), length(N+sum(Ni,1:i-1)))
    end
    if !keepinputs
        # Don't return the inputs in current or in currjac
        ir = length(inputs)+1:length(current)
        outvals = LabeledValues(labels(outvals)[ir], values(outvals)[ir])
    end
    return (outvals, currjac)
end

"""
    filter(labels::AbstractVector{<:Label}, mmr::MMResult)::MMResult

Trims an MMResult down to only those labels in `labels`.  This can optimize calculations
which are carrying a lot of intermediary results that are no longer needed.  All Jacobian
input columns are maintained but only those output rows associated with a label in `labels`
will be retained.  This method reorders the output values to match the order in `labels`.

If the input 'mmr' is N functions of M variables and `length(labels)=P` then the result
will be P functions of M variables.
"""
function filter(labels::AbstractVector{<:Label}, mmr::MMResult)::MMResult
    indexes = map(lbl->indexin(lbl, mmr[1]), labels)
    return ( LabeledValues(labels(mmr[1])[indexes], values(mmr[1])[indexes]), mmr[2][indexes,:] )
end
