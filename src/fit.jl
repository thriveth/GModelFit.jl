
# ====================================================================
struct FitProblem{T <: AbstractMeasures} <: AbstractFitProblem
    timestamp::DateTime
    model::Model
    measures::AbstractMeasures
    resid::Vector{Float64}
    nfree::Int
    dof::Int

    function FitProblem(model::Model, data::T) where T <: AbstractMeasures
        update_step0(model)
        update!(model)
        resid = fill(NaN, length(data))
        nfree = length(free_params(model))
        @assert nfree > 0 "No free parameter in the model"
        return new{T}(now(), model, data, resid, nfree, length(resid) - nfree)
    end
end

free_params(fp::FitProblem) = free_params(fp.model)
residuals(fp::FitProblem) = fp.resid

function update!(fp::FitProblem, pvalues::Vector{Float64})
    update_step1(fp.model, pvalues)
    update_step2(fp.model)
    update_step3(fp.model)
    update_residuals!(fp)
    return fp.resid
end

function update_residuals!(fp::FitProblem{Measures{N}}) where N
    fp.resid .= reshape((fp.model() .- values(fp.measures)) ./ uncerts(fp.measures), :)
end
fit_stat(fp::FitProblem{Measures{N}}) where N =
    sum(abs2, fp.resid) / fp.dof

function finalize!(fp::FitProblem, best::Vector{Float64}, uncerts::Vector{Float64})
    @assert fp.nfree == length(best) == length(uncerts)
    update!(fp, best)
    update_step4(fp.model, uncerts)
end

function error!(fp::FitProblem)
    update_step4(fp.model, fill(NaN, fp.nfree))
end



# ====================================================================
struct MultiFitProblem <: AbstractFitProblem
    timestamp::DateTime
    multi::MultiModel
    fp::Vector{FitProblem}
    resid::Vector{Float64}
    nfree::Int
    dof::Int

    function MultiFitProblem(multi::MultiModel, datasets::Vector{T}) where T <: AbstractMeasures
        @assert length(multi) == length(datasets)
        fp = [FitProblem(multi[id], datasets[id]) for id in 1:length(multi)]
        update!(multi)
        resid = fill(NaN, sum(length.(getfield.(fp, :resid))))
        nfree = sum(getfield.(fp, :nfree))
        @assert nfree > 0 "No free parameter in the model"
        return new(now(), multi, fp, resid, nfree, length(resid) - nfree)
    end
end

free_params(fp::MultiFitProblem) = free_params(fp.multi)
residuals(fp::MultiFitProblem) = fp.resid

function update!(fp::MultiFitProblem, pvalues::Vector{Float64})
    # We need to copy all parameter values before evaluation to ensure
    # all patch functions use the current parameter values
    for (id, i1, i2) in free_params_indices(fp.multi)
        update_step1(fp.multi[id], pvalues[i1:i2])
    end
    update_step2(fp.multi)
    update_step3(fp.multi)

    # Populate resid vector
    i1 = 1
    for id in 1:length(fp.multi)
        update_residuals!(fp.fp[id])
        nn = length(fp.fp[id].resid)
        if nn > 0
            i2 = i1 + nn - 1
            fp.resid[i1:i2] .= fp.fp[id].resid
            i1 += nn
        end
    end
    return fp.resid
end

# TODO: Handle the case where at least one dataset is not a `Measures`
fit_stat(fp::MultiFitProblem) =
    sum(abs2, fp.resid) / fp.dof

function finalize!(fp::MultiFitProblem, best::Vector{Float64}, uncerts::Vector{Float64})
    for (id, i1, i2) in free_params_indices(fp.multi)
        finalize!(fp.fp[id], best[i1:i2], uncerts[i1:i2])
    end
end

function error!(fp::MultiFitProblem)
    for id in 1:length(fp.multi)
        error!(fp.fp[id])
    end
end


# ====================================================================
"""
    FitStats

A structure representing the results of a fitting process.

# Fields:
- `timestamp::DateTime`: time at which the fitting process has started;
- `elapsed::Float64`: elapsed time (in seconds);
- `ndata::Int`: number of data empirical points;
- `nfree::Int`: number of free parameters;
- `dof::Int`: ndata - nfree;
- `fitstat::Float64`: fit statistics (equivalent ro reduced χ^2 for `Measures` objects);
- `status`: minimizer exit status (tells whether convergence criterion has been satisfied, or if an error has occurred during fitting);

Note: the `FitStats` fields are supposed to be accessed directly by the user, without invoking any get() method.
"""
struct FitStats
    timestamp::DateTime
    elapsed::Float64
    ndata::Int
    nfree::Int
    dof::Int
    fitstat::Float64
    # gofstat::Float64
    # log10testprob::Float64
    status::MinimizerStatus
end

function FitStats(fp::AbstractFitProblem, status::MinimizerStatus)
    # gof_stat = sum(abs2, residuals(fp))
    # tp = logccdf(Chisq(fp.dof), gof_stat) * log10(exp(1))
    FitStats(fp.timestamp, (now() - fp.timestamp).value / 1e3,
              length(residuals(fp)), fp.nfree, fp.dof, fit_stat(fp), # tp,
              status)
end



# ====================================================================
"""
    fit(model::Model, data::Measures; minimizer::AbstractMinimizer=lsqfit())

Fit a model to an empirical data set using the specified minimizer (default: `lsqfit()`).
"""
function fit(model::Model, data::Measures; minimizer::AbstractMinimizer=lsqfit())
    fp = FitProblem(model, data)
    status = fit(minimizer, fp)
    return ModelSnapshot(fp.model), FitStats(fp, status)
end

"""
    fit(multi::MultiModel, data::Vector{Measures{N}}; minimizer::AbstractMinimizer=lsqfit())

Fit a multi-model to a set of empirical data sets using the specified minimizer (default: `lsqfit()`).
"""
function fit(multi::MultiModel, data::Vector{Measures{N}}; minimizer::AbstractMinimizer=lsqfit()) where N
    fp = MultiFitProblem(multi, data)
    status = fit(minimizer, fp)
    return ModelSnapshot.(fp.multi.models), FitStats(fp, status)
end


"""
    fit(model::Model; minimizer::AbstractMinimizer=lsqfit())
    fit(model::MultiModel; minimizer::AbstractMinimizer=lsqfit())

Fit a model against dataset(s) of zeros.
"""
fit(model::Model; minimizer::AbstractMinimizer=lsqfit()) =
    fit(model,
         Measures(domain(model), fill(0., length(domain(model))), 1.);
         minimizer=minimizer)

fit(model::MultiModel; minimizer::AbstractMinimizer=lsqfit()) =
    fit(model, [Measures(domain(model[i]), fill(0., length(domain(model[i]))), 1.) for i in 1:length(model)];
         minimizer=minimizer)
