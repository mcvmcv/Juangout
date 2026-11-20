# The posts app: what members write, and the timeline that shows it.
module Posts

using Juango
using Dates

export Post, Like, Tag, for_display, LiveTimeline

const APP = App("posts"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                commands = Dict("seed" => ("Create demo members and posts", args -> seed(args))),
                ready = () -> connect_live_signals())

include("models.jl")
include("admin.jl")
include("templatetags.jl")
include("views.jl")
include("live.jl")
include("urls.jl")
include("commands.jl")

end
