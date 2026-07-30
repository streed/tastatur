module Admin
  # Sites are LISTED in the admin console, never opened.
  #
  # There is no admin route to a site's dashboard and no policy predicate that
  # would allow one. An instance administrator can see that a site exists, which
  # account owns it, and whether it is receiving data — the things you need to
  # answer "my tracking stopped working". They cannot see its pages, referrers,
  # countries or visitors, because those belong to that customer's audience and
  # the whole argument of this product is that we do not browse them.
  #
  # `/dpa` says customer data is never used for our own purposes. A support
  # console that renders someone's top pages would make that a sentence we would
  # have to qualify.
  class SitePolicy < BasePolicy
    def show? = false

    class Scope < BasePolicy::Scope
      def resolve
        superuser? ? scope.all : scope.none
      end
    end
  end
end
