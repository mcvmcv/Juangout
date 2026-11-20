# Middleware: code that wraps every request. This one shows times in the member's own time
# zone: while the request is handled (templates rendered, forms read), their zone is the
# current one. It needs req.user, so it goes after AuthenticationMiddleware.
function MemberTimezoneMiddleware(get_response)
    function (req)
        u = req.user
        if is_authenticated(u) && !isempty(u.time_zone)
            with_timezone(() -> get_response(req), u.time_zone)
        else
            get_response(req)
        end
    end
end
