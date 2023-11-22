# Fragmentary

Fragmentary augments the fragment caching capabilities of Ruby on Rails to support:
* arbitrarily complex dependencies between the content of a fragment and your application data
* multiple versions of individual fragments for different groups of users, e.g. admin vs regular users
* post-cache insertion of user-specific content
* automatic refreshing of cached content when application data changes, without an external client request
* multiple application instances running concurrently with shared application data

Fragmentary has been extracted from [Persuasive Thinking](http://persuasivethinking.com) where it is currently in active use.

## Background
In simple cases, Rails' native support for fragment caching assumes that a fragment's content is a representation of a specific application data record. In the view, the `cache` helper is used to specify the record and to define the content to be rendered within the fragment, e.g.:
```
<% cache product do %>
  <%= render product %>
<% end %>
```
The content is stored in the cache using a _key_ value derived from the record's `id` attribute. The key identifies where the cached content is stored. In addition, a _version_ value derived from the record's `updated_at` attribute is stored along with the content [^1]. If any attributes of the record change, the `updated_at` attribute also changes; the next time a browser requests the content, a mismatch will exist between the calculated and stored values of the version, causing the cache to expire and the fragment to be re-rendered using the current data.

[^1]: Prior to Rails 5.2, the value of `updated_at` was incorporated into the cache key rather that the version. That behavior is still available by setting `config.active_record.cache_versioning = false` in `config/application.rb`. 

For data models with a `has_one` or `has_many` association, nested (Russian Doll) caching is possible with the inner fragment representing the associated record. For example if a product has many games -
```
<% cache product do %>
  <% product.games.each do |game| %>
    <% cache game do %>
      <%= render game %>
    <% end %>
  <% end %>
<% end %>
```
By declaring the `Game` model with `touch: true`, any changes to a game not only cause the inner game fragment to be updated but also the `updated_at` attribute of the product it belongs to, thus updating the outer product fragment as well.
```
class Game < ApplicationRecord
  belongs_to :product, touch: true
end
```

Part of the beauty of this approach is the fact that any change in data requiring the cache to be refreshed is detected by inspecting just a single `updated_at` attribute of each record.  However it is less effective at handling cases where the content of a fragment depends in more complex ways on multiple records from multiple models. The fact that automatic updating of nested fragments is limited to `belongs_to` associations is one aspect of this.

It is certainly possible to construct more complex keys and/or versions from multiple records and models. However this requires retrieving all of those records from the database and computing keys from them for all fragments contained in the server's response every time a request is received, potentially undermining the benefit caching is intended to provide. A related challenge exists in dealing with user-specific content. Here again the user record can easily be incorporated into the key. However if the content of a fragment really must be customized to individual users, this can lead to the number of cache entries escalating dramatically.

A further limitation is that the rendering and storage of cache content relies on an explicit request being received from a user's browser, meaning that at least one user experiences a response time that doesn't benefit from caching every time a relevant change in data occurs. Nested fragments can mitigate this problem for pre-existing pages, since only part of the response need be re-built, though we are still left with the challenge of how to implement nesting in the case of more complex data associations.

## Fragmentary - General Approach
In Fragmentary, view fragments are associated with records from an ActiveRecord model and corresponding database table that are _separate_ from your application data. Records in this table serve only as metadata, recording the type of content each fragment contains, where it is located, and when it was last updated. These records play the same role with respect to caching as an application data record in Rails' native approach, i.e. internally a fragment record is passed to Rails' `cache` method in the same way that `product` was in the earlier example, and the version of a cache entry is derived from the fragment record's `updated_at` attribute. A publish-subscribe mechanism is used to automatically update this timestamp whenever any application data affecting the content of a fragment is added, modified or destroyed, causing the fragment's cached content to be expired.

To support fragment nesting, each fragment record also includes a `parent_id` attribute pointing to its immediate parent, or containing, fragment. Whenever the `updated_at` attribute on an inner fragment changes (initially as a result of a change in some application data the fragment is associated with), as well as expiring the cached content for that fragment, the parent fragment is automatically touched, thus expiring the containing cache as well. This process continues up through all successive ancestors, ensuring that all of the cached content containing the change is refreshed.

Rather than use Rails' native `cache` helper directly, Fragmentary provides some new helper methods that hide some of the necessary internals involved in working with an explicit fragment model. Additional features include the ability to cache separate versions of fragments for different types of users and the ability to insert user-specific content after cached content is retrieved from the cache store. Fragmentary also supports automatic background updating of cached content within seconds of application data changing, avoiding the need for a user to visit a page in order to update the cache.

Plainly, Fragmentary is more complex to use than Rails' native approach to fragment caching, but it provides much greater flexibility. It was initially developed for an application in which this flexibility was essential in order to achieve acceptable page load times for views derived from relatively complex data models and where data can be changed from multiple page contexts and can affect rendered content in multiple ways in multiple contexts.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fragmentary'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fragmentary

## Usage

### Model Setup

Create a database migration for a table to hold the fragment records.

`rails g migration CreateFragments`

Here is a suggested migration (choose any table name you wish):
```
class CreateFragments < ActiveRecord::Migration
  def change
    create_table :fragments do |t|
      t.string :type
      t.index :type
      t.timestamps
      t.belongs_to :root
      t.belongs_to :parent
      t.index :parent_id
      t.integer :record_id
      t.index :record_id
      t.string :user_type
      t.string :key
      t.string :memo
    end
  end
end
```
Run the migration,

`rake db:migrate`

Create a Fragment model and include module `Fragmentary::Fragment` (again, choose whatever model name you wish), e.g.
```
class Fragment < ActiveRecord::Base
  include Fragmentary::Fragment
end
```

In any application data model whose records affect the content of any fragment, include module `Fragmentary::Publisher`, e.g.
```
class Product < ActiveRecord::Base
  include Fragmentary::Publisher
  ...
end
```

Create a `Fragment` subclass (e.g. in app/models/fragments.rb or elsewhere) for each distinct fragment type that your views contain. If a particular fragment type needs to be unique by the id of some application data record, specify the class of the application model as shown in the example below.
```
class ProductTemplate < Fragment
  needs_record_id :type => 'Product'
end
```
Here `needs_record_id` indicates that there is a separate `ProductTemplate` fragment associated with each `Product` record and the `record_id` attribute of a `ProductTemplate` record contains the `id` of that product.

If you need to define further subclasses of your initial subclass, you can declare `needs_record_id` on the latter without providing a type and specify the type separately on the individual subclasses using:

`set_record_type 'SomeModelName'`

We've used this, for example, for fragment types representing different kinds of list items that have certain generic characteristics in common but are used in different contexts to represent content with different sub-class-specific dependencies on application data.

Within the body of the fragment subclass definition, for each application model whose records the content of the fragment depends upon, use the `subscribe_to` method with a block to define methods that handle create, update and destroy events on your application data, typically to touch the fragment records affected by a change in the application data. For example, if product listings include the names of all the categories the products belong to, and those categories are represented by a separate ActiveRecord model, if the wording of a category name changes, you could handle that as follows:
```
class ProductTemplate < Fragment
  needs_record_id :type => 'Product'

  subscribe_to 'ProductCategory' do
    def update_product_category_successful(product_category)
      # touch ProductTemplate records whose record_id matches the ids of products within the specified product_category
      ProductTemplate.where(:record_id => product_category.products.map(&:id)).each(&:touch)
    end
  end
end
```
The effect of this will be to expire the product template fragment for every product contained within the affected category. `subscribe_to` takes one parameter, the name of the application data class being handled, while the names of the methods defined within the block follow the form used in the wisper-activerecord gem, i.e. `create_<model_name>_successful`, `update_<model_name>_successful` and `destroy_<model_name>_successful`, each taking a single argument representing the application data record that has changed.

Within the body of each method that you define within the block, the convenience method `touch_fragments_for_record` can be used retrieve and touch the fragment records affected by the change in application data. This method takes an individual application data record or a record_id or an array of either. So the example above can be written instead as:
```
class ProductTemplate < Fragment
  needs_record_id :type => 'Product'

  subscribe_to 'ProductCategory' do
    def update_product_category_successful(product_category)
      touch_fragments_for_record(product_category.products)
    end
  end
end
```
When implementing the method definitions within the `subscribe_to` block, note that the block will be executed against an instance of a separate `Fragmentary::Subscriber` class that acts on behalf of the particular `Fragment` subclass we are defining. So the methods we define within the block are actually defined on that subscriber object. However, _all other_ methods called on the `Subscriber` object, including those called from within the methods we define in the block, are delegated by `method_missing` to the associated fragment subclass. So in the example, `touch_fragments_for_record` called from within `update_product_category_successful` represents `ProductTemplate.touch_fragments_for_record`. This method is defined by the `Fragment` class, so is available to all fragment subclasses.

Note also that for fragment subclasses that declare `needs_record_id`, there is no need to define a `destroy_<model_name>_successful` method simply to remove a fragment whose `record_id` matches the `id` of a <model_name> application record that is destroyed, e.g. to destroy a `ProductTemplate` whose `record_id` matches the `id` of a destroyed `Product` object. Fragmentary handles this clean-up automatically. This is not to say, however, that 'destroy' handlers are never needed at all. The destruction of an application data record will often require other fragments to be touched.

### View Setup

#### Root Fragments

A 'root' fragment is one that has no parent. In the template in which a root fragment is to appear, define the content to be cached using the `cache_fragment` helper:
```
<% cache_fragment :type => 'ProductTemplate', :record_id => @product.id do |fragment| %>
  <%#  Content to be cached goes here  %>
  ...
<% end %>
```
`cache_fragment` takes a hash of options needed to uniquely identify the fragment. The inclusion of the `:record_id` option is only necessary if we have defined `ProductTemplate` with `needs_record_id`. The `cache_fragment` helper will retrieve an existing fragment record from the database based on the options provided and internally pass that record to Rails' native `cache` method, or if no matching record yet exists it will create one.

#### Nested Fragments

The variable `fragment` that is yielded to the block above is an object of class `Fragmentary::FragmentsHelper::CacheBuilder`, which contains both the actual ActiveRecord fragment record found or created by `cache_fragment` *and* the current template's execution context (i.e. the receiver of the `cache_fragment` method) as instance variables. The class has one public instance method defined, `cache_child`, which can be used to define a child fragment nested within the first. The method is used _within_ a block of content defined by `cache_fragment` and much like `cache_fragment` takes a hash of options that uniquely identify the child fragment. Also like `cache_fragment` it yields another `CacheBuilder` object and wraps a block containing the content of the child fragment to be cached.
```
<% cache_fragment :type => 'ProductTemplate', :record_id => @product.id do |fragment| %>
  <% fragment.cache_child :type => 'StoresAvailable' do |child_fragment| %>
    <%#  Content of the nested fragment to be cached goes here  %>
    ...
  <% end %>
<% end %>
```
Within the body of the child fragment you can continue to define further nested fragments using `child_fragment.cache_child` etc, as long as appropriate fragment subclasses are defined.

Internally, the main difference between `CacheBuilder#cache_child` and `cache_fragment` is that in the former, if an existing fragment matching the options provided is not found and a new record needs to be created, the method will automatically set the `parent_id` attribute of the new child fragment to the id of its parent. This makes it possible for future changes to the child fragment's `updated_at` attribute to trigger similar updates to its parent.

Also note that if the parent fragment's class has been defined with `needs_record_id` but the child fragment's class has _not_, `cache_child` will automatically copy the parent's `record_id` to the child, i.e. the `record_id` propagates down the nesting tree until it reaches a fragment whose class declares `needs_record_id`, at which point it must be provided explicitly in the call to `cache_child`.

#### Lists

Special consideration is needed in the case of fragments that represent lists of variable length. Specifically, we need to be able to properly handle the creation of new list items. Suppose for example, we have a list of stores in which a product is available and a new store needs to be added to the list. In terms of application data, the availability of a product in a particular store might be represented by a `ProductStore` join model. Adding a new store involves creating a new record of this class. This record effectively acts as a 'list membership' association.

There are two fragment types involved in caching the list, one for the list as a whole and another for individual items within it. We might represent the list with a fragment of type `StoresAvailable` and individual stores in the list with fragments of type `AvailableStore`, each of those a child of the list fragment. Both of these fragment types are associated via their respective `record_id` attributes with corresponding application data records. The `StoresAvailable` list fragment is associated with a `Product` record (the product whose availability we are displaying) and each `AvailableStore` fragment is associated with a list membership `ProductStore` record.

We need to ensure that when a new `ProductStore` record is created, the corresponding `AvailableStore` fragment is also created _and_ that the containing `StoresAvailable` fragment is updated as well. We can't simply rely on the creation of the `AvailableStore` to automatically trigger an update to `StoresAvailable` in the way we do when we _update_ a child fragment, because the former _doesn't exist_ until the latter is refreshed.

To address this situation, as a convenience Fragmentary provides a class method `acts_as_list_fragment` that is used when defining the fragment class for the list as a whole, e.g.
```
class StoresAvailable < Fragment
  acts_as_list_fragment :members => :product_stores, :list_record => :product
end
```
The effect of this declaration is to ensure that whenever a new `ProductStore` is created, the `StoresAvailable` record for the corresponding product will be touched, so that the next time the list is rendered, the required new `AvailableStore` fragment will be created.

`acts_as_list_fragment` takes two named arguments:
* `members` is the name of the list membership association in snake case, or tableized, form. The creation of an association of that type is what triggers the addition of a new item to the list. In the example, it is the creation of a new `product_store` that results in a new item being added to the list. Note that the value of the `members` argument should match the record type of the list item fragments (i.e. the type provided to `needs_record_id` in the definition of the list item fragment class). So in the example, the `AvailableStore` class would be defined with `needs_record_id, :type => ProductStore` (We recognize there's some implicit redundancy here that could be problematic; some adjustment may be made in the future).
* `list_record` is either the name of a method (represented by a symbol) or a `Proc` that defines how to obtain the `record_id` (or the record itself; either will work) associated with the list fragment from a given membership association. So, in the example, the membership association is a `ProductStore` record, say `product_store`, and `:product` is the method that would be called on `product_store` to produce the product whose `id` is the `record_id` of the `StoresAvailable` list fragment that needs to be touched when a new list item is created (`:product_id` would also work). Sometimes, however, a simple method like this is insufficient and a `Proc` may be used instead. The newly created membership association is passed as a parameter to the `Proc` and we can implement whatever functional relationship is necessary to obtain the list record. In this simple example, if we wanted (for no good reason) to use a `Proc`, it would look like `->(product_store){product_store.product}`.

Note that in the example, the specified `list_record` method, `:product`, returns a single record for a given `product_store` membership association. However this isn't necessarily always the case. The method or `Proc` may also return an array of records or record_ids.

Another important consideration is that if the list fragment, a `StoresAvailable` fragment in the example, is nested within another, it _must actually exist_ in order for the update to work. If your template is written in such a way that the list fragment is only generated if there are list items to be displayed, say like this,
```
<% cache_fragment :type => 'ProductTemplate', :record_id => @product.id do |product_fragment| %>
  <% if @product.product_stores.any? %>
    <% product_fragment.cache_child :type => 'StoresAvailable' do |stores_fragment| %>
      <% fragment.cache_child :type => 'AvailableStore', :record_id => store.id do |store_fragment| %>
        <%# ... %>
      <% end %>
    <% end %>
  <% end %>
<% end %>
```
then creating an initial product_store association won't add the initial item since the `StoresAvailable` list fragment doesn't exist. Instead you should do something like the following.

```
<% cache_fragment :type => 'ProductTemplate', :record_id => @product.id do |product_fragment| %>
  <% product_fragment.cache_child :type => 'StoresAvailable' do |stores_fragment| %>
    <% @product.product_stores.each do |store| %>
      <% fragment.cache_child :type => 'AvailableStore', :record_id => store.id do |store_fragment| %>
        <%# ... %>
      <% end %>
    <% end %>
  <% end %>
<% end %>
```

It is also worth noting that you are completely free to create lists without using `acts_as_list_fragment` at all. You just have to make sure that you explicitly provide a handler yourself in a `subscribe_to` block to touch any affected list fragments when a new membership association is created. In the example, this would look like the following.
```
class StoresAvailable < Fragment
  subscribe_to 'ProductStore' do
    def create_product_store_successful(product_store)
      touch_fragments_for_record(product_store.product)
    end
  end
end
```

In fact there can be cases where it is necessary to take an explicit approach like this. Using `acts_as_list_fragment` assumes that we can identify the list fragments to be touched by identifying their associated `record_id`s (this is the point of the method's `list_record` parameter). However, we have seen a situation where the set of list fragments that needed to be touched required a complex inner join between the `fragments` table and multiple application data tables, and this produced the list fragments to be touched directly rather than a set of associated record_ids.

### Accessing Fragments by Arbitrary Application Attributes

The examples above involved fragments associated with specific application data records via the `record_id` attribute. The fragments were uniquely identified by the `record_id`, the fragment type, and the `parent_id` if the fragment is nested.

Of course, it is not always necessary to have a `record_id`, for example in a fragment representing a list of items on an index page. On the other hand, there are also cases where something other than a `record_id` is needed in order to uniquely identify a fragment. Suppose, for example, you have a fragment that renders a set of books published in a certain year, a set of restaurants in a certain postcode, or a set of competitors in a sporting event within a particular age-group category. In cases like these we need to be able to uniquely identify the fragment again by its type and sometimes its `parent_id` (if it is nested), but also by some other parameter, which we refer to as a 'key' (the terminology may be a little unfortunate; this is not the same thing as a _cache key_).

To facilitate this, the fragment model includes a `key` attribute that can be customized on a per-class basis using the `needs_key` method. For example,
```
class BooksInYear < Fragment
  needs_key :year_of_publication
end
```

With this definition we can define the cached content like this:
```
<% (first_year..last_year).each do |year| %>
  <% cache_fragment :type => 'BooksInYear', :year_of_publication => year do |fragment| %>
    <%# ... %>
  <% end %>
<% end %>
```
Internally, the `key` attribute is a string, but the value of the custom option passed to either `cache_fragment` or `cache_child` (`year` in the example above) can be a string or anything that responds to `to_s`. Declaring `needs_key` also creates an instance method on your class with the same name as the key, so if you need to access the value of the key from the fragment, instead of writing `fragment.key` you could in this example write `fragment.year_of_publication`.

### User Specific Content

#### Customizing Based on User Type
In the context of a website that identifies users by some form of authentication, often the content served by the site needs to be different for different groups of users. A common example is the case where administrative users see special privileged information or capabilities on a page that are not available to regular users. Similarly, a signed-in user may see a different version of a page from a user who is not signed in.

In the context of caching, this means that separate versions of some content may need to be stored in the cache for each distinct group of users. Fragmentary supports this by means of the `user_type` attribute on the `Fragment` model. This is a string identifying which type of user the corresponding cached content is intended for. Typical examples would be `"admin"`, `"signed_in"` and `"signed_out"`.

The fragment subclass definition for a fragment representing content that needs to be customized by user type should include the `needs_user_type` declaration:
```
class MyFragment < Fragment
  needs_user_type
  ...
end
```
For a fragment subclass like this, when you define an individual fragment in the view, Fragmentary needs to be able to initially create and then subsequently retrieve the fragment record using the correct `user_type` value. One way to do this is to pass a user type to either the `cache_fragment` or `cache_child` method explicitly. This presumes that in the case of authenticated users, a user object is available in the template and that you can derive a corresponding `user_type` string for that object. For example, if you use the [Devise gem]( https://github.com/plataformatec/devise) to provide authentication, by default an authenticated user is represented by the method `current_user`. Since the method returns `nil` if the user is not signed in, the `user_type` passed to `cache_fragment` could be provided as follows (assuming here that a method `is_an_admin?` is defined for your user model),
```
<% user_type = current_user ? (current_user.is_an_admin? ? "admin" : "signed_in") : "signed_out" %>
<% cache_fragment :type => 'MyFragment', :user_type => user_type do %>
  ...
<% end %>
```
This will store the `user_type` string in the fragment record when it is first created and then use that string to retrieve the fragment record on subsequent requests.

However specifying the `user_type` explicitly like this every time you insert a fragment is actually not necessary. Fragmentary allows you to pre-configure both the method used in your template to obtain the user object and the method used to map that object to the `user_type` string. That string will then be automatically inserted into the fragment specification implicitly whenever you use `cache_fragment` or `cache_child` with a fragment `type` that references a class defined with `needs_user_type`. So in the template you don't need to provide any additional parameters:
```
<% cache_fragment :type => 'MyFragment' do %>
  ...
<% end %>
```

To configure Fragmentary to use this approach, create a file, say `fragmentary.rb`, in `config/initializers` and add something like the following:
```
Fragmentary.setup do |config|
  config.current_user_method = :current_user
  config.default_user_type_mapping = ->(user) {
    user ? (user.is_an_admin? ? "admin" : "signed_in") : "signed_out"
  }
end
```
The variable `config` yielded to the `setup` block above represents `Fragmentary.config` which is an instance of class `Fragmentary::Config`. The value assigned to `config.current_user_method` is a symbol representing the method Fragmentary will call on the current template to obtain the current user object. It is up to you to ensure that the method exists for your application. The default value is `:current_user` (so you wouldn't actually need to specify the value used in the example above).

The value assigned to `config.default_user_type_mapping` is a `Proc` to which Fragmentary will pass whatever user object is returned by `config.current_user_method`. When called, the method returns the required `user_type` string.

As well as configuring a `default_user_type_mapping` as shown above, it is also possible to specify a mapping on a per-class basis when declaring `needs_user_type`:
```
class MyFragment < Fragment
  needs_user_type
    :user_type_mapping => -> (user) {
      user ? (user.paid_subscriber? ? "paid" : "unpaid") : nil
    }
end
```
Whether you specify the user type mapping in Fragmentary's configuration or in a class declaration, declaring `needs_user_type` results in a class method `MyFragment.user_type(user)` being added to your fragment subclass.


#### Per-User Customization
While storing different versions of fragments is a workable solution for different groups of users, sometimes content needs to be customized for individual users. It is _possible_ to accomplish this by defining a fragment subclass with the declaration `needs_user_id`:
```
class MyFragment < Fragment
  needs_user_id
  ...
end
```
You will also need to include a `user_id` column in the migration used to create your fragments database table. The `needs_user_id` declaration will result in separate fragments being created for each individual user. As in the case of `needs_user_type`, the `user_id` parameter is automatically extracted from your configured (or default) `current_user_method`.

However this approach is _not_ generally recommended as doing so at any realistic scale is likely to introduce significant cost and performance challenges. Instead, we provide a way for user-specific content (in general any content) to be inserted into a cached fragment _after_ it has been retrieved from the cache through the use of a special placeholder string in a view template. To accomplish this, two classes are defined, `Fragmentary::Widget` and a subclass `Fragmentary::UserWidget`. Instances of these classes represent chunks of content that will be inserted into a fragment after it has been either rendered and stored or retrieved from the cache. For each type of insertable content you wish your application to support, define a specific subclass of one of these classes (`UserWidget` is preferred if the content is to be user-specific) with two instance methods:
- `pattern`, which returns a `Regexp` that will be used to detect a placeholder you will use in your template at the point where you wish the inserted content to be placed. The placeholder consists of a string matching the regular expression you specify wrapped in special delimiter characters `%{...}`.
- `content`, which returns the string that will be inserted in place of the placeholder.

To give a very simple and contrived example, you could define a widget as:
```
class SoupWidget < Fragmentary::Widget
  def pattern
    Regexp.new('random_soup')
  end

  def content
    ["vegetable", "chicken noodle", "French onion", "beef lentil",
     "cream of mushroom", "minestrone, "Thai coconut chicken", "pumpkin"].sample
  end
end
```
and in your template insert that widget content by writing,
```
<% cache_fragment :type => 'Menu' do |fragment| %>
  ...
  <p>The soup of the day is <%= "%{random_soup}" %></p>
  ...
<% end %>
```

The point to note is that the specific soup in the example is _not_ stored in the cache; it is inserted only after the cached content is retrieved by `cache_fragment` (or alternatively `cache_child`). Once you've defined the `Widget` subclass, inserting the placeholder into your template is all you have to do to make use of the widget. Fragmentary takes care of detecting the placeholder and inserting the widget's non-cached content into the content retrieved from the cache.

You can also pass variable data into your widget by including parenthesized capture groups within the widget's regular expression pattern. For example, with a pattern like this,
```
class MenuWidget < Fragmentary::Widget
  def pattern
    Regexp.new('menu_for_(\w*)')
  end
end
```
you could specify a placeholder,
```
<%= "%{menu_for_tuesday}" %>
```
The Ruby `MatchData` object that results from matching the placeholder in your template against the widget's pattern is available via the read accessor `Fragmentary::Widget#match`. Any substrings matched against parenthesized capture groups are accessible as `match[1]`, `match[2]`... etc. So in the example, the string `"tuesday"` would be available within your `content` method as `match[1]`.

Internally, the widget is instantiated with the current template as an instance variable and you can access it within your `content` method via a read accessor, `template`. This means that within `content` you can use any methods normally available within an Action View template simply by calling them on the template object explicitly. So in the last example, the menu content could be inserted by rendering a partial:
```
class MenuWidget < Fragmentary::Widget
  def pattern
    Regexp.new('menu_for_(\w*)')
  end

  def content
    template.render 'menu_for', :day => match[1]
  end
end
```
With all of the foregoing, we can now see how to insert user-specific content. For example we could define a widget like this one,

```
class WelcomeMessage < Fragmentary::UserWidget
  def pattern
    Regexp('welcome_message')
  end

  def content
    "Welcome #{current_user.display_name}, member since #{current_user.membership_year}"
  end
end
```
and insert it into a template with,
```
<p><%= "%{welcome_message}" %></p>
```
Notice that in this case we subclassed `UserWidget` instead of `Widget`. The only differences between the two are that:
- as a convenience, `UserWidget` provides a read accessor `current_user` to save you having to write `template.send(Fragmentary.config.current_user_method)`.
- if `current_user` is nil because no user is signed in, `content` will return an empty string.

### The 'memo' Attribute and Conditional Content

With the exception of `updated_at`, the attributes of the fragment model we have discussed, `type`, `record_id`, `parent_id`, `key`, and `user_type`, are all designed for one purpose: to uniquely identify a fragment record. Occasionally, however, we may need to attach additional information to a fragment record, e.g. regarding the content contained within the fragment.

Suppose you wish the inclusion of a piece of cached content in your template to be conditional on the result of some computation that occurs _within_ the process of rendering of that content. This could arise, for example, if database records needed for the fragment are retrieved within the body of the fragment (in order to avoid having to access the database when a cached version of the fragment is available), and the fragment is either shown or hidden selectively, depending on whether some variable derived from that data matches another parameter, say a user input.

Of course if you have to render the content in order to determine whether it needs to be included, you defeat the purpose of caching. However, the fragment `memo` attribute included in the database migration suggested earlier can be used to address this. The process involves three parts:
* wrap the `cache_fragment` or `cache_child` method that defines the fragment content with a Rails `capture` block and assign the result to a local variable.
* Inside the block passed to `cache_fragment` or `cache_child`, update the fragment's `memo` attribute with the data that will be used to determine whether the fragment will be displayed.
* After calling the `capture` helper, test the fragment's `memo` attribute and conditionally insert the 'captured' content into the template.

```
<% conditional_content = capture do %>
  <% cache_fragment :type => 'ProductTemplate', :record_id => @product.id do |fragment| %>
    <%#  Content to be cached goes here  %>
    <%#  ...                             %>
    <% fragment.update_attribute(:memo, computed_memo_value) %>
  <% end %>
<% end %>

<% if Fragment.root(:type => 'ProductTemplate', :record_id => @product.id).memo == required_memo_value %>
  <%= conditional_content %>
<% end %>
```

Note that we update the fragment's `memo` attribute by calling `update_attribute` on the `fragment` object. Although this is actually a `CacheBuilder` object, that class passes any methods such as `update_attribute` to the underlying fragment.

Also note the use above of the method `Fragment.root` to retrieve the fragment matching the supplied parameters after caching has occurred. We have to retrieve the fragment explicitly since the variable `fragment` is local to the `cache_fragment` block to which it is yielded. The method takes the same parameters as `cache_fragment` with one exception: At present, if your fragment class declares `needs_user_type` or `needs_user_id`, you need to explicitly pass either the respective parameter or the current user object (this may change in a future release). e.g.

```
...
<% root_fragment = Fragment.root(:type => 'ProductTemplate', :record_id => @product.id, :user => current_user).memo == required_memo_value %>
...
```

The process for child fragments is similar, except that an instance method Fragment#child can be called on the parent fragment in order to retrieve the fragment to be tested. e.g.

```
<% conditional_content = capture do %>
  <% parent_fragment.cache_child :type => 'StoresAvailable' do |fragment| %>
    <%#  Content to be cached goes here  %>
    <%#  ...                             %>
    <% fragment.update_attribute(:memo, computed_memo_value) %>
  <% end %>
<% end %>

<% if parent_fragment.child(:type => 'StoresAvailable').memo == required_memo_value %>
  <%= conditional_content %>
<% end %>
```

In both of these examples, the fragment to be tested is retrieved after caching. If relying on side-effects doesn't make you too queasy, you can alternatively retrieve it before caching, in which case the retrieved fragment can be passed to `cache_fragment` or `cache_child` as appropriate instead of the set of fragment attributes we used before. This avoids the need for `cache_fragment` or `cache_child` to retrieve the fragment themselves internally, e.g.
```
<% root_fragment = Fragment.root(:type => 'ProductTemplate', :record_id => @product.id) %>
<% conditional_content = capture do  %>
  <% cache_fragment :fragment => root_fragment do |fragment| %>
    <%#  Content to be cached goes here  %>
    <%#  ...                             %>
    <% fragment.update_attribute(:memo, computed_memo_value) %>
  <% end %>
<% end %>

<% if root_fragment.memo == required_memo_value %>
  <%= conditional_content %>
<% end %>
```
Note that both `Fragment.root` and `Fragment#child` will instantiate a matching fragment if one doesn't already exist. If you prefer to handle the case where a matching fragment doesn't already exist separately, you can instead use `Fragment.existing` or `Fragment#existing_child`, which return nil if a matching fragment isn't found rather than instantiating one, e.g.
```
<% if child = parent_fragment.existing_child(:type => 'StoresAvailable') %>

  <% conditional_content = capture do %>
    <% parent_fragment.cache_child(:child => child) do |fragment| %>
      ...
    <% end %>
  <% end %>

  <% if child.memo == required_memo_value %>
    <%= conditional_content %>
  <% end %>

<% else %>
  <%# handle this case differently %>
  ...
<% end %>
```

### Updating Cached Content Automatically

#### Internal Application Requests

When application data that a cached fragment depends upon changes, i.e. as a result of a POST, PATCH or DELETE request, the `subscribe_to` declarations in your `Fragment` subclass definitions ensure that the `updated_at` attribute of any existing fragment records affected will be updated. Then on subsequent browser requests, the cached content itself will be refreshed.

As part of this process, new fragment records may be created as *children* of an existing fragment if the existing fragment contains newly added list items. A new *root* fragment, on the other hand, will be created for any root fragment class defined with `needs_record_id` if an application data record of the associated `record_type` is created, as soon as a browser request is made for the new content (often a new page) containing that fragment.

Sometimes, however, it is desirable to avoid having to wait for an explicit request from a user in order to update the cache or to create new cached content. To deal with this, Fragmentary provides a mechanism to automatically create or refresh cached content preemptively, essentially as soon as a change in application data occurs. Rails' `ActionDispatch::Integration::Session` [class](https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/testing/integration.rb) provides an interface that allows requests to be sent directly to the application programmatically, without generating any external network traffic. Fragmentary uses this interface to automatically send requests needed to update the cache whenever changes in application data occur. These 'internal' requests are sent asynchronously so that they do not delay the response to the external POST, PATCH or DELETE request from the user's browser that brought about the change in application data.

Creating internal requests is handled slightly differently depending on whether they are designed to update content associated with an existing root fragment or to create content for a new root fragment that does not yet exist. In the case of an existing root fragment, if the fragment's class has a `request_path` *instance* method defined, a request will be sent to the application at that path (represented in the form of a string) whenever `touch` is called on the fragment record (If required, the request can be suppressed by passing `:no_request => true` to `touch`). You simply need to define the `request_path` method in any individual `Fragment` subclass that you wish to generate requests for. For example:
```
class ProductTemplate < Fragment
  needs_record_id :type => 'Product'

  def request_path
    "/product/#{record_id}"
  end
end
```
Since nested child fragments automatically touch their parent fragments when they themselves are updated, internal requests can be initiated by an update to application data that affects a fragment anywhere within a page. Only the root fragment needs to define the request path.

The request that is generated will be sent to the application at the `request_path` specified, but it may also include additional request parameters and options. To send HTTP request parameters with the request, the `Fragment` subclass should define an additional instance method `request_parameters` that returns a hash of named parameters. To send an XMLHttpRequest, a class should define an instance method `request_options` that returns the hash `{:xhr => true}`.

In the case of a root fragment that *does not* yet exist, i.e. for a `Fragment` subclass defined with `needs_record_id` and an associated `record_type` when a new application record of that type is first created, a request will be generated in order to create the new fragment automatically if the subclass has a *class* method `request_path` defined that takes the `id` of the newly created application record and returns a string representing the path to which the request should be sent. For example:
```
class ProductTemplate < Fragment
  needs_record_id :type => 'Product'

  def self.request_path(record_id)
    "/product/#{record_id}"
  end

  def request_path
    self.class.request_path(record_id)
  end
```

So in this example, any time a new `Product` record is created, Fragmentary will send a request to the page for that new product, resulting in the corresponding `ProductTemplate` fragment being created. As shown here, in cases like this we generally choose to define the instance method `request_path` in terms of the corresponding class method.

#### Request Queues

A single external HTTP POST, PATCH or DELETE request can cause changes to application data affecting multiple fragments on multiple pages. One external request can therefore lead to multiple internal application requests. In addition, given that different versions of some cached fragments may exist for different user types, we may need to send each internal request multiple times in the context of several different user sessions (representing different user types), to ensure that all affected versions get refreshed.

To achieve this, during the handling of the initial external request that causes the application data to change, the internal requests created as a result are represented by instances of the class `Fragmentary::Request` and are initially stored in a number of 'queues' represented by instances of the class `Fragmentary::RequestQueue`. Separate queues exist for each of the different user types supported by the fragments to be rendered, and individual requests to a given endpoint are automatically placed in multiple queues as needed. However, responsibility for actually sending the requests stored in the queues is offloaded to an asynchronous process using Rails' `ActiveJob` interface (as detailed below under [Sending Queued Requests](https://github.com/MarkMT/fragmentary#sending-queued-requests)).

`Fragment` subclasses inherit both class and instance methods `request_queues` that return a hash of queues keyed by each of the specific user type strings that that specific subclass supports. So, for example, a `ProductTemplate` fragment may have two different request queues, `ProductTemplate.request_queues["admin"]` and `ProductTemplate.request_queues["signed_in"]`.

The set of user types that an individual `Fragment` subclass is expected to support is available via a configurable class method `user_types`, which returns an array of user type strings (Note this is different from the class method `user_type` discussed earlier that returns a single user type for a specific current user). Configuration of the `user_types` method is discussed in the next section.

The request queue for any given user type is shared across all `Fragment` subclasses within the application. So for example,`ProductTemplate.request_queues["signed_in"]` and `StoreTemplate.request_queues["signed_in"]` both represent the same object.

#### Configuring Internal Request Users

The user types each subclass supports can be configured in two ways. If all of the fragments in your application that declare `need_user_type` always use the same set of user types, you can configure these by setting `Fragmentary.config.session_users` in your `initializers/fragementary.rb` file:

```
Fragmentary.setup do |config|
  ...
  config.session_users = {
    'signed_in' => {:credentials => {:user => {:email => 'bob@example.com', :password => 'bobs_secret'},
    'admin' => {:credentials => {:user => {:email => 'alice@example.com', :password => 'alices_secret'}
  }
  config.get_sign_in_path = '/users/sign_in'
  config.post_sign_in_path = '/users/sign_in'
  config.sign_out_path = '/users/sign_out'
end
```

The value assigned to `session_users` is a hash whose keys are each a required `user_type` string, with values containing a hash of credentials needed to sign in as a stereotypical user for that type, i.e. the HTTP request parameters that need to be sent with a POST request to sign in. If authentication is not required, the value should be an empty hash. If you prefer not to put credentials in the configuration file directly, you can alternatively specify a `Proc` that returns the required hash; the `Proc` will be executed when sign-in actually occurs. We have used this, for example, to retrieve randomized single-use credentials from our User model for specific test users that have only read-access to the site.

As shown in the example, we also need to assign sign-in and sign-out paths, with separate sign-in paths for GET and POST requests. The GET path is the address from which a user would retrieve the sign-in form. Fragmentary sends a GET request to this address first in order to retrieve the CSRF token that needs to be submitted with the user credentials in a POST request when signing in.

The configuration defined using `Fragmentary.setup` as shown above will be used as the default for any fragment subclass defined using `needs_user_type`; for those subclasses the class method `user_types` will return an array of the `user_type` strings so defined. However, if you need a specific subclass to support a different set of user types, you can configure that by passing additional options to `needs_user_type` in the class definition.

```
class MyFragment < Fragment
  needs_user_type
    :session_users => ['admin',
                       'paid' => {:credentials => ...},
                       'unpaid' => {:credentials => ...}]
end
```

The value of the `:session_users` option (you can also use `:user_types` or just `:types` instead) is an array containing either strings of user types that are defined elsewhere, e.g. using `Fragmentary.setup` (e.g. 'admin' in the example) or hashes of new session user definitions that include their required sign-in credentials.

#### Sending Queued Requests

Internal requests stored in the application's request queues are typically sent using an `after_action` filter in your `ApplicationController`, e.g. for create, update and destroy actions:
```
class ApplicationController
  after_action :send_queued_requests, :only => [:create, :update, :destroy]

  def send_queued_requests
    Fragmentary::RequestQueue.send_all(:between => 10.seconds)
  end
end
```
The optional named argument `between` represents the interval between individual requests in each queue being sent and allows you to throttle the request rate. If it is present (including `:between => 0.seconds`), the requests will be sent asynchronously using ActiveJob. If omitted, requests will be sent immediately (i.e before the response to the original external request is sent to the user's browser).

You can customize further by sending requests from queues individually. A class method `Fragmentary::RequestQueue.all` returns an array of all request queues that the application uses. The requests stored within an individual queue can be sent by calling the instance method `RequestQueue#send`.
```
def send_queued_requests
  delay = 0.seconds
  Fragmentary::RequestQueue.all.each{|q| q.send(:delay => delay += 10.seconds)}
end
```
`send` takes two optional named arguments, `delay` and `between`. `delay` represents the delay before the queue begins sending requests and `between` again represents the interval between individual requests. In the example above, we choose to delay the sending of requests from each queue by 10 seconds each. If either are present (including `:delay => 0`), the requests will be sent asynchronously using ActiveJob. If omitted, all requests held in the queue are sent immediately.

When requests are sent using either `send` or `send_all`, a `Fragmentary::UserSession` object is instantiated representing a browser session for the particular type of user the queue is handling. For sessions representing user types that need to be authenticated, instantiating the `UserSession` automatically signs in to the application using the credentials configured for the particular `user_type`.

ActiveJob supports a number of adapters for executing tasks asynchronously. You should configure according to your own needs. For example, to use Fragmentary with the [Delayed::Job](https://github.com/collectiveidea/delayed_job) gem, you would add the following to your `config/application.rb` file:
```
config.active_job.queue_adapter = :delayed_job
```
and add the 'delayed_job_active_record' gem to your Gemfile. Consult the [ActiveJob documentation](https://guides.rubyonrails.org/active_job_basics.html#backends) for more information as well as the documentation for your chosen adapter on how to start background task processes when you deploy your application.

#### Queuing Requests Explicitly

In the cases we've described so far, internal requests are added to request queues automatically, either as a result of updating an existing root fragment or because a new application record has been created that requires a new root fragment with a class declaration `needs_record_id` to be created. There are, however, sometimes cases in which you may wish to create `Fragmentary::Request` objects yourself and add them to the appropriate queues explicitly. This could arise, for example, with a fragment class that declares `needs_key`. If a change in application data results in a value of the 'key' that didn't previously exist, you may wish, in a `subscribe_to` block within your fragment subclass definition, to create an internal request explicitly that will result in new cached content being generated for that new 'key' value.

The process is straightforward. First instantiate a request by calling `Fragmentary::Request.new`. This method takes two required parameters and two optional parameters:

```
request = Fragmentary::Request.new(method, path, parameters, options)
```

`method` is a string, usually 'get', but in general 'post', 'patch', 'put' and 'delete' are also acceptable values.

`path` is a string representing the path you wish the request to be sent to.

`parameters` is an optional hash containing named HTTP request parameters to be sent with the request.

`options` is an optional hash `{:xhr => true}` if the request is to be sent as an `XMLHttpRequest`.

Once the request is instantiated, you can add it to all of the queues required by the fragment's subclass simply by calling the class method `queue_request`:
```
MyFragment.queue_request(request)
```

### Asynchronous Fragment Updating

Off-loading internal application requests to an asynchronous process as noted in the previous section means they can occur without delaying the server's response to the user's initial external request. However, in a complex application there may also be some overhead just in the process of updating fragment records that is not critical in order to send a response back to the user. For example, some application data changes may require a large number of fragments to be updated on pages other than the one the user is going to be sent or redirected to right away. In this case, we may wish to offload the task of updating these fragments to an asynchronous process as well.

Fragmentary accomplishes this by means of the `Fragmentary::Handler` class. An individual task you wish to be handled asynchronously is created by defining a subclass of `Fragmentary::Handler`, typically within the scope of the `Fragment` subclass in which you wish to use it. The `Handler` subclass you define requires a single instance method `call`, which defines the task to be performed.

To use the handler, typically within a fragment's `subscribe_to` declaration, call the inherited class method `create`, passing it a hash of named arguments. Those arguments can then be accessed within your `call` method as the instance variable `@args`. Consider our earlier example in which each product template contains a list of stores in which the product is available. Suppose an administrator fixes a typographical error in the name of a store. That correction needs to propagate to every `AvailableStore` fragment for every product that is available in that store. We can do this using a Handler as follows:
```
class AvailableStore < Fragment
  needs_record_id :type => 'ProductStore'

  class UpdateStoreHandler < Fragmentary::Handler
    def call
      product_stores = ProductStore.where(:store_id => @args[:id])
      touch_fragments_for_record(product_stores)
    end
  end

  subscribe_to 'Store' do
    def update_store_successful(store)
      UpdateStoreHandler.create(store.attributes.symbolize_keys)
    end
  end
end
```
While a `Handler` subclass definition defines a task to be run asynchronously, and calling the class method `create` within a `subscribe_to` block causes the task to be instantiated, we still have to explicitly dispatch the task to an asynchronous process. We again do this using ActiveJob in an `ApplicationController` `after_filter`. In fact we can combine both the sending of background requests and the asynchronous fragment updating task in one method:

```
def handle_asynchronous_tasks
  send_queued_requests  # as defined earlier
  Fragmentary::DispatchHandlersJob.perform_later(Fragmentary::Handler.all)
  Fragmentary::Handler.clear
end
```
Here `Fragmentary::DispatchHandlersJob` is a subclass of `ActiveJob::Base`, which means if you wish you can specify additional options using the `set` method, e.g.
```
Fragmentary::DispatchHandlersJob.set(:wait => 1.minute, :queue => 'low_priority').perform_later(Fragmentary::Handler.all)
```
Also note that updating fragments in an asynchronous process like this will itself generate internal application requests beyond those generated in the course of handling the user's initial request. `DispatchHandlersJob` also takes care of sending these additional requests.

#### Updating Lists Asynchronously

As discussed earlier, if a fragment class is declared with `acts_as_list_fragment`, fragments of that class will be automatically touched whenever a new list item is created. If you want this process to take place asynchronously, simply pass the option `:delay => true` to `acts_as_list_fragment`, e.g.:
```
class StoresAvailable < Fragment
  acts_as_list_fragment :members => :product_stores, :list_record => :product, :delay => true
end
```

### Updating Fragments Explicitly Within a Controller

The typical usage scenario for Fragmentary is for fragment records to be updated by the methods defined in the `subscribe_to` blocks you create in your fragment subclasses, in response to user requests that modify the application data. This involves very little coupling between your application's controllers and models and the fragment caching process. Models need only include the `Fragmentary::Publisher` module to ensure that `Fragment` subclasses can subscribe to the application data events that trigger fragment updates. Your `ApplicationController` only needs to ensure that any queued internal requests and asynchronous fragment update tasks are dispatched (if you choose to use either of those features) before sending a response to the user's browser. Application models and controllers generally have no need to access the `Fragment` class API.

Ocassionally, however, a situation may arise in which it is useful to touch fragments directly from a controller. For example, an application data event may occur that requires fragments to be updated on a large number of different pages within your site. This is the kind of scenario in which you might choose to offload fragment updating to a `Fragmentary::Handler` and execute the task asynchronously as described in the previous section. However, it may also be that *one* of those pages is the one that is going to be sent back to the user's browser immediately in response to the current request. You can't put off touching the affected fragment on that one page until the asynchronous process executes because then the user won't see the updated content. In a scenario like this, you also can't detect within the `subscribe_to` block in your fragment subclass definition which one fragment needs to be touched immediately rather than asynchronously, since the fragment class has no knowledge of the internal state of the controller.

A possible solution in this situation may be to touch the fragment representing the content that is about to be returned to the user *in the controller*. We're *not* convinced that this is good practice, but if you decide you need to, you can use the class method `Fragment.existing` to obtain the required fragment in the controller and call `touch` on it explicitly. If the fragment subclass involved is one that supports multiple user types, you will want to ensure that just the fragment corresponding to the current user's `user_type` is touched, which you can do by passing the current user object to `existing`. Internally, `existing` will map the user object to the corresponding `user_type` using the `user_type_mapping` you have configured in order to select the correct fragment. In addition, when you touch the fragment in this context, you should pass `:no_request => true` so that it doesn't generate an internal request to update the cache since responding to the user's actual request is going to accomplish this automatically.

```
class ProductStoresController < ApplicationController
  def create
    ...
    @product_store.save
    fragment = ProductTemplate.existing(:record_id => @product_store.product_id, :user => current_user)
    fragment.touch(:no_request => true)
  end
end
```

### Removing Queued Requests in the Controller

Another scenario that occasionally arises is when internal requests created in the course of executing methods defined in a `subscribe_to` block include the path to the same page that the controller is going to render anyway in the normal course of responding to the user's current browser request. In effect, that one internal request is redundant. Although it generally won't cause any real harm to send a redundant request (remember the internal request is usually dispatched asynchronously, so it won't interfere with the synchronous response), redundancy is redundancy and you may wish to avoid it.

In this case, it is possible within the controller to remove a request that has already been queued, after the application data has been created, updated or destroyed, by using the class method `Fragment.remove_queued_request`. The method takes two named parameters, the path of the request to be removed and the current user object, with the latter allowing it to remove the request from the correct queue, e.g.

```
class ProductsController < ApplicationController
  def create
    ...
    if @product.save
      respond_to do |format|
        format.html do
          ProductTemplate.remove_queued_request(:request_path => "/products/#{@product.id}", :user => current_user)
          redirect_to @product
        end
        format.js
      end
    else
      ...
    end
  end
end
```

### Handling AJAX Requests

#### Providing a Receiver for Calls to 'cache_child'
There are a couple of special issues to consider when using Fragmentary with templates designed to respond to partial page requests. An example would be a Javascript template used to insert content into a previously loaded page, such as when dynamically adding a new item to an existing list. The typical approach in this scenario is to use embedded Ruby (ERB) in the Javascript template to render a partial containing the required content, escape the resulting string for Javascript and insert it into the list using jQuery's `append` method, e.g.

```
$('ul.product_list').append('<%= j(render 'product/summary', :product => @product) %>')
```

However, it's possible for the partial to contain a cached fragment that happens to be a child of a parent containing the list as a whole. In this case, when the entire page containing the original list is first rendered and the parent fragment is retrieved using say `cache_fragment` (if it happens to be a root fragment), a `CacheBuilder` object is yielded to the block that renders the partial, and this object is passed to the partial to act as the receiver for `cache_child`.
```
<% cache_fragment :type =>`ProductList` do |parent_fragment| %>
  <ul class='product_list'>
    <% @products.each do |product| %>
      <% render 'product/summary', :product => product, :parent_fragment => parent_fragment %>
    <% end %>
  </ul>
<% end %>
```
In the Javascript case, however, since the template only renders the new list item and not the list as a whole, there is no `cache_fragment` method invoked in order to yield the `CacheBuilder` object, and so we have to construct it explicitly. To do this, Fragmentary provides a helper method `fragment_builder` that takes an options hash containing the parameters that define the fragment (the same ones passed to `cache_fragment`) and returns the `CacheBuilder` object that the partial needs.
```
<% parent_fragment = fragment_builder(:type => 'ProductList') %>
$('ul.product_list').append('<%= j(render 'product/summary', :product => @product,
                                                             :parent_fragment => parent_fragment) %>')
```

#### Inserting Widgets into Child Fragments

The second challenge in dealing with child fragments rendered without the context provided by a call to `cache_fragment` concerns the insertion of widgets into the generated content. Ordinarily, when a full page is rendered in response to the initial browser request, any widgets that are required are inserted after the root fragment has been either created or retrieved. This occurs within the `cache_fragment` method. But again, if we are only rendering part of the page containing a child fragment, there is no call to `cache_fragment` in which this can occur.

To address this, `cache_child` can take an additional boolean option, `:insert_widgets` that can be used to force the insertion of widgets into the child. Typically a local variable containing the value of this option would be passed to the partial in which `cache_child` appears. In the Javascript template:
```
<% parent_fragment = fragment_builder(:type => 'ProductList') %>
$('ul.product_list').append('<%= j(render 'product/summary', :product => @product,
                                                             :parent_fragment => parent_fragment,
                                                             :insert_widgets => true) %>')
```
Then in the partial itself, something like this:
```
<% insert_widget ||= nil %>
<% parent_fragment.cache_child :type => 'ProductSummary', :insert_child => insert_child do |fragment| %>
  <li>
    ...
  </li>
<% end %>
```
Note that if the partial page content being generated contains several nested child fragments, the `:insert_widgets` option only needs to be passed to the outer-most call to `cache_child`.

### Suppressing Cache Storage

It is possible to define a fragment without actually storing its content in the cache store. This can be useful, for example if you wish to cache several sibling children within a page but don't need to store the entire root fragment that contains them. Simply include the option `:no_cache => true` in the hash passed to `cache_fragment` or `cache_child`.

### Support for Multiple Application Instances

In many practical deployment scenarios it is desirable to maintain a live pre-release version of the application online separate from the public-facing production website. This allows new software releases to be staged for either internal or beta testing prior to final deployment to the production environment. For example, if the public-facing application is accessed at a root URL of http://myapp.com/, a separate pre-release version might be deployed say to http://prerelease.myapp.com/ or http://myapp.com/prerelease/.

In the specific scenario in which Fragmentary was developed, it was important for the pre-release version of the application to share the same application database as the production site, i.e. both production and pre-release versions render exactly the same data, and any changes to application data initiated by a user of one version of the application will be reflected in the content seen by a user of the other version as well. For caching, this leads to some additional challenges which we discuss below.

#### Storing Multiple Versions of Content in the Cache

There is an important difference between the content rendered by each instance of an application: any HTML links to other pages on the site must be to URLs representing the particular version being rendered. For example, on a 'products' index page, a link to an individual product page on the production website might look like http://myapp.com/products/123, while the same link on the index page of the pre-release version might be http://myapp.com/prerelease/products/123.

In general, as long as links contained in the view are created using Rails' standard path or url helpers, e.g. `product_path(@product)`  etc, they will automatically be based on the root URL of the application instance (production or pre-release) in which they are generated. However, in the context of caching, the fact that differences exist in the content generated by different application instances implies that for each fragment defined in the view by calling `cache_fragment` or `cache_child`, different versions of fragment content need to be stored in the cache. Also, each of these distinct versions needs to be associated with a unique record in the `fragments` database table identifying which application instance generated that content.

In Fragmentary we can accomplish this simply by adding a column to the `fragments` table to store the root URL of the particular application instance that created the fragment content.

```
class AddAppUrlToFragment < ActiveRecord::Migration
  def change
    change_table :fragments do |t|
      t.string :application_root_url
    end
  end
end
```

The column name `application_root_url` shown above is the default assumed by Fragmentary. You can use a different column name if you wish, as long as you tell Fragmentary in initializers/fragmentary.rb, e.g.:

```
Fragmentary.setup do |config|
  ...
  config.application_root_url_column = 'app_root'
end
```

Once this column has been added to the `fragments` table, any fragment records subsequently created by calls to `cache_fragment` or `cache_child` will have the column populated automatically based on the particular application instance in which the code is executed, and the content stored in the cache for each fragment record will be that generated by the corresponding instance. As long as any links rendered within the content are generated using Rails' path or url helpers, the cached content will be rendered correctly both when initially created and when retrieved subsequently.

Note that it is possible to store cached content for each of the different application instances in different places. Simply set `config.cache_store` in config/environments/production.rb (or alternative environment file) as required.

#### Automatically Refreshing Multiple Versions of Cached Content

The fact that two versions of content exist in the cache for each fragment means that whenever a change in application data occurs that triggers the generation of an internal application request to refresh a piece of cached content (i.e. for any fragment that has a `request_path` method defined), _both_ (in general all) versions need to be refreshed. So for example, a change to application data caused by a user action on the production website needs to trigger internal requests to _both_ the production _and_ the pre-release instances in order to refresh their respective content. The converse is true for changes initiated from the pre-release website.

(Note: for better or worse, we've stuck with the term 'internal request' to mean any request delivered to the application programmatically in order to refresh cached content. This includes requests created by one application instance that are intended to be processed by another instance.)

Our approach to sending requests between application instances relies on processing requests asynchronously and directing the tasks used to do this to specific task queues associated with the application instance they are intended to be processed by. Each application instance has an associated asynchronous task process (in our case using Delayed::Job). By configuring that process to run tasks from just the queue(s) designated for it, we ensure that any application instance can direct requests to any other. As long as queued tasks are stored in a database table (as they are, for example, using Delayed::Job) and provided that each instance of the application has access to the same database, this approach achieves our objective. The way we accomplish this in practice is outlined below.

First, to configure Fragmentary to automatically refresh cached content for multiple instances, set `remote_urls` in `Fragmentary.config`. This is an array of root URLs for all _other_ instances of the application that requests should be sent to. For example, in order to allow requests to be sent from the production instance to the pre-release instance, in initializers/fragmentary.rb in the production code we would add the following configuration:

```
Fragmentary.setup do |config|
  ...
  config.remote_urls << 'http://myapp.com/prerelease/'
end
```

Our current approach to application deployment is to maintain different branches in our source repository for each application instance. This allows us to keep custom configurations like `config.remote_urls` above for each instance on their own branches. So in contrast to the case above, to allow requests to be sent from the pre-release instance to the production instance, in initializers/fragmentary.rb on the pre-release branch the `remote_urls` array would be set to `['http://myapp.com/']` .

As an alternative, it would also be possible to create a separate environment for the pre-release deployment in your config/environments directory and thus maintain the configuration for all application instances in a single repository branch. We have not investigated this approach.

By specifying `remote_urls` as described above, for each internal application request Fragmentary will automatically create tasks to process the request not only on the application instance where it was created but also on all other instances corresponding to the elements in `remote_urls`. Fragmentary sends these tasks to named queues whose names are formed automatically from the domain name and path of both the root URL of the current instance and the values in `remote_urls`. So in the example, a request to '/products/123', created say by editing a product name on the production website, would be sent to queues with names 'myapp.com/' and 'myapp.com/prerelease/'.

The final step is to configure the asynchronous processes associated with each application instance to execute tasks from the correct queue. In our case, we use [Delayed::Job](https://github.com/collectiveidea/delayed_job) to handle asynchronous tasks and Capistrano 2 for deployment. We set `delayed_job_args` in `config/deploy.rb` to configure the queue names as follows (see documentation [here](https://github.com/collectiveidea/delayed_job/blob/master/lib/delayed/recipes.rb)):
```
queue_prefix = "myapp.com/prerelease/"
set :delayed_job_args, "--queue=#{queue_prefix}"
after "deploy:stop",    "delayed_job:stop"
after "deploy:start",   "delayed_job:start"
after "deploy:restart", "delayed_job:restart"
```
Again, this configuration will be different for each instance, and so in our case each one is stored in different source repository branches.

Note that if you configure [Delayed::Job](https://github.com/collectiveidea/delayed_job) (or other backend) to work only from specific queues, you'll need to make sure that _any_ asynchronous tasks created by your application are submitted to one of those queues.

## Dependencies

  - Fragmentary is currently being used in production with Rails 6.0. Versions >=0.4 do not work with earlier versions of Rails for a couple of reasons:
    - The version of ActiveJob in Rails 5.x does not support the custom serialization needed to enqueue asynchronous tasks for sending internal requests. A repository branch 'delayed_job' is available that uses the [Delayed::Job](https://github.com/collectiveidea/delayed_job) gem directly (i.e. without ActiveJob) and this works well with Rails 5.x. However, this branch is no longer maintained.
    - The API for the Rails `ActionDispatch::Integration::Session` class, which is used to handle internal application requests, was changed in Rails 5.0. Consequently the current version of Fragmentary is incompatible with Rails 4.x and earlier. We do have a 'Rails.4.2' branch in the repository that uses the older API. However, this branch is no longer maintained.

## Timestamps

Fragmentary allows HTML comments to be optionally inserted into cached fragments identifying the time at which the fragment was last cached. Simply add `config.insert_timestamps = true` to the configuration block in your `config/initializers/fragmentary.rb` file.

It is also possible to insert comments identifying a version name for the application code in use at the time the fragment was cached and the time at which that version was deployed. This is accomplished by dynamically adding values for the configuration settings `Fragmentary.config.release_name` and `Fragmentary.config.deployed_at` to your `config/initializers/fragmentary.rb` file at the time you deploy. ie. within your deployment script you need to arrange to append something like the following to that file.
```
Fragmentary.config.release_name = release_name
Fragmentary.config.deployed_at = deployed_at
```
It is up to you how you define/determine these values, but `deployed_at` would typically represent the value of `Time.now.utc` at the time the deployment script is executed. If these two configuration values are set, and `Fragmentary.config.insert_timestamps` is set to true, Fragmentary will automatically insert comments along the lines of the following:
```
<!-- ProductDetails 2382 cached by Fragmentary version 0.4 at 2023-09-22 09:28:02 UTC -->
<!-- Cached using application release 20230919233149 deployed at 2023-09-19 23:33:16 UTC -->
... Cached content appears here ...
<!-- ProductDetails 2382 ends -->
```

## Utility Methods

The `Fragment` class and its subclasses provide a number of utility instance methods that are typically useful for interacting with fragments from the console.
  - `touch_or_destroy` - recursively touches the fragment record and all decendant fragments for which cache entries exist. Destroys any fragment records in the tree for which no cache entry exists.
  - `cache_exist?` - returns a boolean indicating whether fragment has content stored in the cache.
  - `content` - retrieves the fragment's cached content
  - `delete_cache` - removes the fragment's content from the cache.
  - `delete_cache_tree` - recursively removes from the cache all content for the fragment and its descendants.

## Contributing

Bug reports and usage questions are welcome at https://github.com/MarkMT/fragmentary.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
