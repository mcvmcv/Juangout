# A view takes a request and returns a response.
function home(req)
    render(req, "home.html", Dict("tagline" => "Say what's on your mind. Briefly."))
end
