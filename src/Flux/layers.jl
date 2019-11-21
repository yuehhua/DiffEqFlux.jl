#= using Flux.Tracker: @grad =#
using Zygote: @adjoint
using DiffEqSensitivity: adjoint_sensitivities_u0

## Reverse-Mode via Flux.jl

#= function diffeq_rd(p,prob,args...;u0=prob.u0,kwargs...) =#
#=   if typeof(u0) <: AbstractArray && !(typeof(u0) <: TrackedArray) =#
#=     if DiffEqBase.isinplace(prob) =#
#=       # use Array{TrackedReal} for mutation to work =#
#=       # Recurse to all Array{TrackedArray} =#
#=       _prob = remake(prob,u0=convert.(recursive_bottom_eltype(p),u0),p=p) =#
#=     else =#
#=       # use TrackedArray for efficiency of the tape =#
#=       _prob = remake(prob,u0=convert(typeof(p),u0),p=p) =#
#=     end =#
#=   else # u0 is functional, ignore the change =#
#=     _prob = remake(prob,u0=u0,p=p) =#
#=   end =#
#=   solve(_prob,args...;kwargs...) =#
#= end =#

## Forward-Mode via ForwardDiff.jl

function diffeq_fd(p,f,n,prob,args...;u0=prob.u0,kwargs...)
  _prob = remake(prob,u0=convert.(eltype(p),u0),p=p)
  f(solve(_prob,args...;kwargs...))
end

diffeq_fd(p::TrackedVector,args...;kwargs...) = Flux.Tracker.track(diffeq_fd, p, args...; kwargs...)
Flux.Tracker.@grad function diffeq_fd(p::TrackedVector,f,n,prob,args...;u0=prob.u0,kwargs...)
  _f = function (p)
    _prob = remake(prob,u0=convert.(eltype(p),u0),p=p)
    f(solve(_prob,args...;kwargs...))
  end
  _p = Flux.data(p)
  if n === nothing
    result = DiffResults.GradientResult(_p)
    ForwardDiff.gradient!(result, _f, _p)
    DiffResults.value(result),Δ -> (Δ .* DiffResults.gradient(result), ntuple(_->nothing, 3+length(args))...)
  else
    y = adapt(typeof(_p),zeros(n))
    result = DiffResults.JacobianResult(y,_p)
    ForwardDiff.jacobian!(result, _f, _p)
    DiffResults.value(result),Δ -> (DiffResults.jacobian(result)' * Δ, ntuple(_->nothing, 3+length(args))...)
  end
end

## Reverse-Mode using Adjoint Sensitivity Analysis
# Always reduces to Array

function diffeq_adjoint(p,prob,args...;u0=prob.u0,kwargs...)
  _prob = remake(prob,u0=u0,p=p)
  T = gpu_or_cpu(u0)
  adapt(T, solve(_prob,args...;kwargs...))
end

#= diffeq_adjoint(p::TrackedVector,prob,args...;u0=prob.u0,kwargs...) = =#
#=   Flux.Tracker.track(diffeq_adjoint, p, u0, prob, args...; kwargs...) =#

@adjoint function diffeq_adjoint(p,u0,prob,args...;backsolve=true,
                              save_start=true,
                              sensealg=SensitivityAlg(quad=false,backsolve=backsolve),
                              kwargs...)

  T = gpu_or_cpu(u0)
  _prob = remake(prob,u0=u0,p=p)

  # Force save_start in the forward pass
  # This forces the solver to do the backsolve all the way back to u0
  # Since the start aliases _prob.u0, this doesn't actually use more memory
  # But it cleans up the implementation and makes save_start arg safe.
  sol = solve(_prob,args...;save_start=true,kwargs...)

  # If didn't save start, take off first. If only wanted the end, return vector
  only_end = length(sol_idxs) <= 1
  u = sol[sol_idxs]
  only_end && (sol_idxs = length(sol))
  out = only_end ? sol[end] : reduce((x,y)->cat(x,y,dims=ndims(u)),u.u)
  out, Δ -> begin
    function df(out, u, p, t, i)
      if only_end
        out[:] .= -vec(Δ)
      else
        out[:] .= -reshape(Δ, :, size(Δ)[end])[:, i]
      end
    end

    ts = sol.t
    du0, dp = adjoint_sensitivities_u0(sol,args...,df,ts;
                    sensealg=sensealg,
                    kwargs...)
    (dp', reshape(du0,size(u0)), ntuple(_->nothing, 1+length(args))...)
  end
end
