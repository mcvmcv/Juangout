# The notifications app: telling members when someone follows them, likes or replies to a post.
module Notifications

using Juango
using Dates
using ..Posts: Post
using ..Accounts: Member

export Notification, Verb, unread_notifications

const APP = App("notifications"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns,
                ready = () -> connect_signals(),     # run once, when the app is installed
                # a setting of the app's own, for links in emails; the project can override it
                settings = Dict(:SITE_URL => "http://127.0.0.1:8000"))

include("models.jl")
include("tasks.jl")
include("signals.jl")
include("views.jl")
include("urls.jl")

end
