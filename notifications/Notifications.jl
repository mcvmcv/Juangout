# The notifications app: telling members when someone follows them, likes or replies to a post.
module Notifications

using Juango
using Dates
using ..Posts: Post
using ..Accounts: Member

export Notification, Verb, unread_notifications

const APP = App("notifications"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                ready = () -> connect_signals())     # run once, when the app is installed

include("models.jl")
include("tasks.jl")
include("signals.jl")
include("views.jl")
include("urls.jl")

end
