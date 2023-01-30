mutable struct Polynomial <: AbstractComponent
    p::Vector{Parameter}
    Polynomial(args...) = new(Parameter.([args...]))
end


function evaluate!(buffer::Vector{Float64}, comp::Polynomial, x::AbstractDomain{1},
                   coeffs...)
    buffer .= coeffs[1]
    for deg in 1:length(coeffs)-1
        buffer .+= coords(x).^deg .* coeffs[deg+1]
    end
end
