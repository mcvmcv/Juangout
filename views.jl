function home(req)
    render(req, "home.html", Dict("notes" => objects(Note)[1:10]))
end
