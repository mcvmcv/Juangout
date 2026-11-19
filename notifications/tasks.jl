# Email about a notification. A background task: it runs outside the request, so a slow mail
# server never slows a page down. (With the default TASKS = :immediate it runs straight away;
# chapter 15 hands tasks to a worker process.)
@background function email_notification(id)
    n = get(select_related(objects(Notification), :recipient, :actor, :post); id)
    member = n.recipient
    (isempty(member.email) || !member.email_notifications) && return
    body = render_to_string("notifications/email.txt", Dict("n" => n, "site_url" => Juango.settings.SITE_URL))
    send_mail("$(n.actor.name) $(n.get_verb_display) on Juangout", body, nothing, [member.email])
end
