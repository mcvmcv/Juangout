# The posts app: what members write, and the timeline that shows it.
module Posts

using Juango
using Dates

export Post, Like, for_display

const APP = App("posts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                commands = Dict("seed" => ("Create demo members and posts", args -> seed(args))))

include("models.jl")
include("admin.jl")
include("views.jl")
include("urls.jl")
include("commands.jl")

end
