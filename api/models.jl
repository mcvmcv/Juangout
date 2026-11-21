# An API token: a secret a member gives a program, so it can act as them. Only a hash of the
# secret is stored, as with passwords: someone who reads the database can't use the tokens.
@model struct ApiToken
    member = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :api_tokens)
    name = CharField(max_length = 50, help_text = "What it's for, so you can recognise it later.")
    key_hash = CharField(max_length = 64, unique = true, editable = false)
    created = DateTimeField(auto_now_add = true)
    last_used = DateTimeField(null = true, blank = true, editable = false)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, t::ApiToken) = print(io, t.name)

hash_key(key) = bytes2hex(sha256(key))

"Make a token for `member`. Returns the token and its secret key, which is never stored."
function new_token!(member, name)
    key = randstring(RandomDevice(), 40)          # RandomDevice: the operating system's secure randomness
    token = create(ApiToken; member, name, key_hash = hash_key(key))
    token, key
end

"The active member a key belongs to, or `nothing`. Notes when the token was last used."
function member_for_key(key)
    token = first(select_related(filter(ApiToken; key_hash = hash_key(key)), :member))
    (token === nothing || !token.member.is_active) && return nothing
    update!(filter(ApiToken; id = token.id); last_used = timezone_now())
    token.member
end
